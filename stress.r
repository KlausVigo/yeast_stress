require(phangorn)
require(DESeq)
require(PIGShift)
require(DAAG)
require(ape)

readExpressOutput = function(speciesNames,geneNamesFile) {
	#read in the gene names
	geneNames = unlist(read.table(geneNamesFile,stringsAsFactors=FALSE))	
	#learn all the conditions from the first one
	curDirs = list.dirs(speciesNames[1])
	curDirs = curDirs[2:length(curDirs)] #gets rid of the top level one	
	fields = strsplit(curDirs,"_")
	conditions = unique(sapply(fields,function(x){x[length(x)-1]}))
	dat = data.frame(row.names=geneNames)
	solvable = rep(FALSE,length(geneNames))
	for (sample in speciesNames) {
		for (condition in conditions) {
			curDirs = list.files(sample,full.names=TRUE,pattern=paste("_",condition,"_",sep=""))
			#print(curDirs)
			for (dir in curDirs) {
				curFiles = list.files(dir,pattern=".named.xprs",full.names=TRUE)
				#print(curFiles)
				for (file in curFiles) {
					curDat = read.table(file,header=TRUE,stringsAsFactors=FALSE)
					curSampleCond = unlist(strsplit(file,"/"))[2]
					print(curSampleCond)	
					curMatch = match(geneNames,curDat$target_id)
					solvable = solvable|curDat$solvable[curMatch]
					curCounts = as.numeric(curDat$eff_counts[curMatch])
					dat = cbind(dat,curCounts)
					colnames(dat)[ncol(dat)]=curSampleCond
					#print(head(curDat))
					#print(head(dat))
				}
			}
		}
	} 
	#clean up the data
	#Remove any rows where any dude has NA or if it's not solvable
	dat = dat[apply(dat,1,function(x){!any(is.na(x))})&solvable,]
	return(dat)
}

generateCountDataSet = function(speciesNames,geneNamesFile) {
	print("Reading the files")
	dat = readExpressOutput(speciesNames,geneNamesFile)	
	conditions = sapply(strsplit(colnames(dat),"_"),function(x){paste(x[1:(length(x)-1)],collapse="_")})
	condFact = factor(conditions)
	print("Converting to CountDataset")
	myCountDataSet = newCountDataSet(round(dat),condFact)
	print("Estimating size factors")
	myCountDataSet = estimateSizeFactors(myCountDataSet)
	print("Estimating dispersions")
	myCountDataSet = estimateDispersions(myCountDataSet)
	return(myCountDataSet)
}

getPhyloData = function(countDataSet,condition,speciesSet,log=TRUE,normalize=1) {
	countData = counts(countDataSet,normalized=TRUE)
	phyloData = matrix(nrow=nrow(countData),ncol=length(speciesSet))
	rownames(phyloData)=rownames(countData)
	colnames(phyloData)=speciesSet
	for (species in speciesSet) {
		speciesCond = paste(species,condition,sep="_")
		curDat = countData[,conditions(countDataSet)==speciesCond]
		curMean = rowMeans(curDat)
		phyloData[,species] = curMean	
	}
	if (log) {
		if (any(phyloData<=0)) {
			warning("Some counts are <= 0. Removing any gene with any counts <= 0")
		}
		phyloData = phyloData[apply(phyloData,1,function(x){!any(x<=0)}),]
		phyloData = log(phyloData)
	}
	if (log&&normalize) {
		phyloData = apply(phyloData,1,function(x){x-x[normalize]})	
	} else if (normalize) {
		warning("To normalize data, it should be log-transformed. Proceeding with normalization regardless")
		phyloData = apply(phyloData,1,function(x){x-x[normalize]})
	}
	return(t(phyloData))
}

findDEgenes = function(countDataSet,speciesSet,p.cut=.1) {
	conditions = unique(sapply(strsplit(as.character(pData(countDataSet)$condition),"_"),function(x){x[length(x)]}))
	DEgenes = list()
	for (species in speciesSet) {
		print(paste("Processing",species))
		for (i in 1:(length(conditions)-1)) {
			for (j in (i+1):length(conditions)) {
				cat(paste(" ...",conditions[i],"vs",conditions[j]))
				res = nbinomTest(countDataSet,paste(species,conditions[i],sep="_"),paste(species,conditions[j],sep="_"))
				resSig = res[res$padj<p.cut,]
				DEgenes[[paste(species,conditions[i],conditions[j],sep="_")]] = resSig$id
			}	
		}
		cat("\n")
	}
	return(DEgenes)
}

compute_intersection = function(geneList,speciesNames,cond) {
	samples = paste(speciesNames,cond,sep="_")
	myIntersection = Reduce(intersect,geneList[samples])	
	return(myIntersection)
}

compute_exclusive = function(geneList,speciesIncluded,speciesExcluded,cond) {
	goodSamples = paste(speciesIncluded,cond,sep="_")
	badSamples = paste(speciesExcluded,cond,sep="_")
	badGenes = Reduce(union,geneList[badSamples])
	goodGenes = Reduce(intersect,geneList[goodSamples])
	myExclusive = setdiff(goodGenes,badGenes)
	return(myExclusive)
}

compute_identity = function(fasta_dir) {
	myFiles = list.files(fasta_dir,full.names=TRUE)
	conservation = c()
	names = c()
	good_sites = c()
	cur_file_num = 1
	for (file in myFiles) {
		if (cur_file_num%%100==0) {print(cur_file_num)}
		cur_file_num = cur_file_num + 1
		name = unlist(strsplit(file,"/"))
		name = name[length(name)]
		name = unlist(strsplit(name,".",fixed=TRUE))[1]
		dna = read.dna(file,format="fasta",as.character=TRUE)
		if (is.null(dim(dna))) {
			warning(paste("Dimensions of data wrong for ", file, ". Skipping.",sep=""))
			next
		}
		conserved = sum(apply(dna,2,function(x){length(unique(x))==1&&!("-"%in%x)}))
		total = sum(apply(dna,2,function(x){!("-"%in%x)}))
		conservation = c(conservation,conserved/total)
		names = c(names,name)
		good_sites = c(good_sites,total)
	}
	names(conservation) = names
	names(good_sites) = names
	return(list(conservation=conservation,good_sites=good_sites))
}

empirical_bayes_rates = function(dat,test,phy,norm=FALSE) {
	#assumes that test is a result of test.groups
	#returns a matrix of empirical Bayes MAP rates
	#dat should be the same shape as expected by PIGShift
	best_model = cbind(1:nrow(test$wAIC),apply(test$wAIC,1,which.max))
	best_alpha = test$alpha[best_model]
	best_beta = test$beta[best_model]
	best_shift = test$shift[best_model]
	vcv_list = list()
	for (i in 1:nrow(best_model)) {
		if (best_model[i,2] == ncol(test$wAIC)) {
			vcv_list[[i]] = OU.vcv(phy,best_shift[i])
		} else {
			rates = rep(1,nrow(phy$edge))
			rates[test$branches[[best_model[i,2]]]]=best_shift[i]
			vcv_list[[i]] = updatevcv(phy,rates)
		}

		if (norm) {
			vcv_list[[i]] = normalize.vcv(vcv_list[[i]],norm)
			vcv_list[[i]] = vcv_list[[i]][-norm,-norm]
		}
	}
	dat = dat[-norm,]
	betaTilde = sapply(vcv_list,function(v){best_beta+apply(dat,2,function(x){mahalanobis(x,mean(x),v)})})
	betaTilde = matrix(betaTilde,ncol=nrow(test$wAIC))
	alphaTilde = best_alpha + nrow(dat)/2
	return(betaTilde/(alphaTilde+1))
}


#modified from Jonathan Eastman's package, auteur
updatevcv = function(ape.tre, new.rates) {
	vv=vcv(updatetree(ape.tre, new.rates))
	return(vv)
}

#borrowed from Jonathan Eastman's package, auteur
updatetree = function(ape.tre, new.rates){
	ape.tre$edge.length=ape.tre$edge.length*new.rates
	return(ape.tre)
}


dnaRateshiftLike = function(phy,dna,branches,rate,shift) {
	phy$edge.length[branches]=phy$edge.length[branches]*shift
	pml(phy,dna,rate=rate,model="JC")$logLik
}

testDNAshift = function(phy,dna,branches) {
	#first get the likelihood of the best fitting single rate model
	singleOptim = optim(c(1),function(pars) {-dnaRateshiftLike(phy,dna,branches,pars[1],1)},gr=NULL,method="L-BFGS-B",lower=c(.01,.01),upper=c(10,10))
	#then get likelihood of best shift model
	shiftOptim = optim(c(1,1),function(pars) {-dnaRateshiftLike(phy,dna,branches,pars[1],pars[2])},gr=NULL,method="L-BFGS-B",lower=c(.01,.01),upper=c(10,10))
	LRT = -2*(shiftOptim$value-singleOptim$value)
	return(list(singleRate=singleOptim$par,shiftRate=shiftOptim$par,singleLL=singleOptim$value,shiftLL=shiftOptim$value,LRT=LRT))
}

readFastaToPhyDat = function(fastaFile,badNames,goodNames) {
	dna.matrix = read.dna(fastaFile,format="fasta",as.character=TRUE)
	curNames = rownames(dna.matrix)
	nameMapping = sapply(badNames,grep,curNames)
	dna.matrix = dna.matrix[nameMapping,]
	rownames(dna.matrix)=goodNames
	return(phyDat(dna.matrix))
}

testDNAshift.group = function(phy,group,branches,alignDir,badNames,goodNames) {
	res = list()
	for (i in 1:length(group)) {
		if (i%%round(length(group)/10)==0) print(i)
		if (is.na(group[i])) {
			warning("Encountered an NA. Skipping")
			next
		}
		dat = readFastaToPhyDat(paste(alignDir,"/",group[i],".fa",sep=""),badNames,goodNames)
		res[[i]] = testDNAshift(phy,dat,branches)
	}
	return(res)
}

buildTree = function(fastaFile,phy,badNames,goodNames,model="JC",k=4) {
	dat = readFastaToPhyDat(fastaFile,badNames,goodNames)
	optPML = pml(phy,dat,model=model,k=k)
	optPML = optim.pml(optPML,optNni=TRUE,model=model,optInv=TRUE,optGamma=TRUE)
	return(optPML)
}

testConservation = function(conservation,group,numTest = 10000) {
	num_good = sum(!is.na(conservation$conservation[group]))
	groupMean = mean(conservation$conservation[group],na.rm=T)
	testMeans = c()
	for (i in 1:numTest) {
		curMean = mean(sample(conservation$conservation[!is.na(conservation$conservation)],num_good))
		testMeans = c(testMeans,curMean)
	}
	return(list(groupMean=groupMean,testMeans=testMeans))	
}

readConcatenatedDNA = function(group,alignDir,badNames,goodNames) {
	concatenated.dna = c()
	for (i in 1:length(group)) {
		if (is.na(group[i])) {
			warning("Encountered an NA. Skipping")
			next
		}
		curFile = paste(alignDir,"/",group[i],".fa",sep="")
		curDat = read.dna(curFile,format="fasta",as.character=TRUE)
		curNames = rownames(curDat)
		nameMapping = sapply(badNames,grep,curNames)
		curDat = curDat[nameMapping,]
		concatenated.dna = cbind(concatenated.dna,curDat)
	}
	rownames(concatenated.dna) = goodNames
	return(concatenated.dna)
}

readConcatenatedPhyDat = function(group,alignDir,badNames,goodNames) {
	initialized = FALSE
	for (i in 1:length(group)) {
		if (is.na(group[i])) {
			warning("Encountered an NA. Skipping")
			next
		}
		curFile = paste(alignDir,"/",group[i],".fa",sep="")
		curDat = readFastaToPhyDat(curFile,badNames,goodNames)
		if (!initialized) {
			concatenated.dna = curDat
			initialized=TRUE
		} else {
			concatenated.dna = c(concatenated.dna,curDat)
		}
	}
	return(concatenated.dna)
}

#phy is an ape tree
#group is a list of gene
#alignDir is a directory in which to look for fasta files
##it will look for genes as alignDir/gene.fa
#badNames is a regular expression that captures some aspect of the names of the organisms in the fasta files
#goodNames should correspond to phy$tip.labels
#model is model
#k is k
#optNni is optNni
fitTreeConcatenate = function(phy,group,alignDir,badNames,goodNames,model="GTR",k=4,optNni=TRUE) {
	concat.dna = readConcatenatedDNA(group,alignDir,badNames,goodNames)
	concat.phyDat = phyDat(concat.dna)
	optPML = pml(phy,concat.phyDat,model=model,k=k)
	optPML = optim.pml(optPML,optNni=optNni,model=model,optInv=TRUE,optGamma=TRUE)
	return(optPML)
}
