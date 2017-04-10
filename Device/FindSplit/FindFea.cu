/*
 * DeviceSplitter.cu
 *
 *  Created on: 5 May 2016
 *      Author: Zeyi Wen
 *		@brief: 
 */

#include <iostream>
#include <thrust/scan.h>
#include <thrust/execution_policy.h>

#include "../../DeviceHost/MyAssert.h"
#include "../../DeviceHost/svm-shared/HostUtility.h"
#include "../KernelConf.h"
#include "../Hashing.h"
#include "../Splitter/DeviceSplitter.h"
#include "../Memory/gbdtGPUMemManager.h"
#include "../Memory/findFeaMemManager.h"
#include "../Memory/SNMemManager.h"
#include "../Bagging/BagManager.h"
#include "FindFeaKernel.h"
#include "IndexComputer.h"

using std::cout;
using std::endl;
using std::make_pair;
using std::cerr;

/**
 * @brief: efficient best feature finder
 */
void DeviceSplitter::FeaFinderAllNode(vector<SplitPoint> &vBest, vector<nodeStat> &rchildStat, vector<nodeStat> &lchildStat, void *pStream, int bagId)
{
	GBDTGPUMemManager manager;
	BagManager bagManager;
	int numofSNode = bagManager.m_curNumofSplitableEachBag_h[bagId];
	int maxNumofSplittable = manager.m_maxNumofSplittable;
//	cout << bagManager.m_maxNumSplittable << endl;
	int nNumofFeature = manager.m_numofFea;
	PROCESS_ERROR(nNumofFeature > 0);

	//reset memory for this bag
	{
		manager.MemsetAsync(bagManager.m_pGDEachFvalueEachBag + bagId * bagManager.m_numFeaValue,
							0, sizeof(float_point) * bagManager.m_numFeaValue, pStream);
		manager.MemsetAsync(bagManager.m_pHessEachFvalueEachBag + bagId * bagManager.m_numFeaValue,
							0, sizeof(float_point) * bagManager.m_numFeaValue, pStream);
		manager.MemsetAsync(bagManager.m_pDenseFValueEachBag + bagId * bagManager.m_numFeaValue,
							0, sizeof(float_point) * bagManager.m_numFeaValue, pStream);

		manager.MemsetAsync(bagManager.m_pGDPrefixSumEachBag + bagId * bagManager.m_numFeaValue,
							0, sizeof(float_point) * bagManager.m_numFeaValue, pStream);
		manager.MemsetAsync(bagManager.m_pHessPrefixSumEachBag + bagId * bagManager.m_numFeaValue,
							0, sizeof(float_point) * bagManager.m_numFeaValue, pStream);
		manager.MemsetAsync(bagManager.m_pGainEachFvalueEachBag + bagId * bagManager.m_numFeaValue,
							0, sizeof(float_point) * bagManager.m_numFeaValue, pStream);
	}
	cudaStreamSynchronize((*(cudaStream_t*)pStream));

	//compute index for each feature value
	IndexComputer indexComp;

	KernelConf conf;
	int blockSizeLoadGD;
	dim3 dimNumofBlockToLoadGD;
	conf.ConfKernel(indexComp.m_totalFeaValue, blockSizeLoadGD, dimNumofBlockToLoadGD);
	if(numofSNode > 1)
	{
		clock_t comIdx_start = clock();
		//compute gather index via GPUs
		indexComp.ComputeIdxGPU(numofSNode, maxNumofSplittable, bagId);
		clock_t comIdx_end = clock();
		total_com_idx_t += (comIdx_end - comIdx_start);
	
		//copy # of feature values of each node
		manager.MemcpyHostToDeviceAsync(indexComp.m_pNumFeaValueEachNode_dh, bagManager.m_pNumFvalueEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable,
										sizeof(long long) * bagManager.m_maxNumSplittable, pStream);
		//copy feature value start position of each node
		manager.MemcpyHostToDeviceAsync(indexComp.m_pFeaValueStartPosEachNode_dh, bagManager.m_pFvalueStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable, 
										sizeof(long long) * maxNumofSplittable, pStream);
		//copy (in pinned mem) of feature values for each feature in each node
		manager.MemcpyHostToDeviceAsync(bagManager.m_pEachFeaLenEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
										bagManager.m_pEachFeaLenEachNodeEachBag_dh + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
										sizeof(int) * bagManager.m_maxNumSplittable * bagManager.m_numFea, pStream);
	
		PROCESS_ERROR(nNumofFeature == bagManager.m_numFea);
		clock_t start_gd = clock();
		//scatter operation
		//total fvalue to load may be smaller than m_totalFeaValue, due to some nodes becoming leaves.
		int numFvToLoad = indexComp.m_pFeaValueStartPosEachNode_dh[numofSNode - 1] + indexComp.m_pNumFeaValueEachNode_dh[numofSNode - 1];
		LoadGDHessFvalue<<<dimNumofBlockToLoadGD, blockSizeLoadGD, 0, (*(cudaStream_t*)pStream)>>>(bagManager.m_pInsGradEachBag + bagId * bagManager.m_numIns, 
															   bagManager.m_pInsHessEachBag + bagId * bagManager.m_numIns, 
															   bagManager.m_numIns, manager.m_pDInsId, manager.m_pdDFeaValue, 
															   bagManager.m_pIndicesEachBag_d, numFvToLoad,
															   bagManager.m_pGDEachFvalueEachBag + bagId * bagManager.m_numFeaValue, 
															   bagManager.m_pHessEachFvalueEachBag + bagId * bagManager.m_numFeaValue, 
															   bagManager.m_pDenseFValueEachBag + bagId * bagManager.m_numFeaValue);
		cudaStreamSynchronize((*(cudaStream_t*)pStream));
		clock_t end_gd = clock();
		total_fill_gd_t += (end_gd - start_gd);
	}
	else
	{
		clock_t start_gd = clock();
		LoadGDHessFvalueRoot<<<dimNumofBlockToLoadGD, blockSizeLoadGD, 0, (*(cudaStream_t*)pStream)>>>(bagManager.m_pInsGradEachBag + bagId * bagManager.m_numIns,
															   	   	bagManager.m_pInsHessEachBag + bagId * bagManager.m_numIns, bagManager.m_numIns,
															   		manager.m_pDInsId, manager.m_pdDFeaValue, indexComp.m_totalFeaValue,
															   		bagManager.m_pGDEachFvalueEachBag + bagId * bagManager.m_numFeaValue,
															   	   	bagManager.m_pHessEachFvalueEachBag + bagId * bagManager.m_numFeaValue,
															   	   	bagManager.m_pDenseFValueEachBag + bagId * bagManager.m_numFeaValue);
		cudaStreamSynchronize((*(cudaStream_t*)pStream));
		clock_t end_gd = clock();
		total_fill_gd_t += (end_gd - start_gd);

		clock_t comIdx_start = clock();
		//copy # of feature values of a node
		manager.MemcpyHostToDeviceAsync(&manager.m_totalNumofValues, bagManager.m_pNumFvalueEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable,
										sizeof(long long), pStream);
		//copy feature value start position of each node
		manager.MemcpyDeviceToDeviceAsync(manager.m_pFeaStartPos, bagManager.m_pFvalueStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable,
									 	 sizeof(long long), pStream);
		//copy each feature start position in each node
		manager.MemcpyDeviceToDeviceAsync(manager.m_pFeaStartPos, bagManager.m_pEachFeaStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
										sizeof(long long) * nNumofFeature, pStream);
		//copy # of feature values of each feature in each node
		manager.MemcpyDeviceToDeviceAsync(manager.m_pDNumofKeyValue, bagManager.m_pEachFeaLenEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
									    sizeof(int) * nNumofFeature, pStream);

		//copy # (in pinned mem) of feature values of each feature in each node
		manager.MemcpyDeviceToDeviceAsync(manager.m_pDNumofKeyValue, bagManager.m_pEachFeaLenEachNodeEachBag_dh + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
										sizeof(int) * nNumofFeature, pStream);

		//set indexComp
		indexComp.m_pFeaValueStartPosEachNode_dh[0] = 0;
		indexComp.m_pNumFeaValueEachNode_dh[0] = manager.m_totalNumofValues;
		clock_t comIdx_end = clock();
		total_com_idx_t += (comIdx_end - comIdx_start);
	}

	//initialise values for gd and hess prefix sum computing
	manager.MemcpyDeviceToDeviceAsync(bagManager.m_pGDEachFvalueEachBag + bagId * bagManager.m_numFeaValue,
									bagManager.m_pGDPrefixSumEachBag + bagId * bagManager.m_numFeaValue,
									sizeof(float_point) * manager.m_totalNumofValues, pStream);
	manager.MemcpyDeviceToDeviceAsync(bagManager.m_pHessEachFvalueEachBag + bagId * bagManager.m_numFeaValue,
									bagManager.m_pHessPrefixSumEachBag + bagId * bagManager.m_numFeaValue,
									sizeof(float_point) * manager.m_totalNumofValues, pStream);

//	cout << "prefix sum" << endl;
	clock_t start_scan = clock();
	//compute the feature with the maximum number of values
	int totalNumArray = indexComp.m_numFea * numofSNode;
	cudaStreamSynchronize((*(cudaStream_t*)pStream));//wait until the pinned memory (m_pEachFeaLenEachNodeEachBag_dh) is filled
	ComputeMaxNumValuePerFea(bagManager.m_pEachFeaLenEachNodeEachBag_dh + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea, totalNumArray, bagId);
	//cout << "max # of values per fea is " << bagManager.m_pMaxNumValuePerFeaEachBag[bagId] <<"; # of arrays is " << totalNumArray << endl;
	cudaDeviceSynchronize();

	//construct keys for exclusive scan
	int *pnKey_d;
	int keyFlag = 0;
	checkCudaErrors(cudaMalloc((void**)&pnKey_d, bagManager.m_numFeaValue * sizeof(int)));
	long long *pTempEachFeaStartEachNode = bagManager.m_pEachFeaStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea;
	long long *pTempEachFeaStartEachNode_h = new long long[totalNumArray];
	checkCudaErrors(cudaMemcpy(pTempEachFeaStartEachNode_h, pTempEachFeaStartEachNode, sizeof(long long) * totalNumArray, cudaMemcpyDeviceToHost));
	for(int m = 0; m < totalNumArray; m++){
		unsigned int arrayLen = bagManager.m_pEachFeaLenEachNodeEachBag_dh[m];
		unsigned int arrayStartPos = pTempEachFeaStartEachNode_h[m];
		checkCudaErrors(cudaMemset(pnKey_d + arrayStartPos, keyFlag, sizeof(int) * arrayLen));
		if(keyFlag == 0)
			keyFlag = -1;
		else 
			keyFlag = 0;
	}
	delete[] pTempEachFeaStartEachNode_h;

	//compute prefix sum for gd and hess (more than one arrays)
	float_point *pTempGDSum = bagManager.m_pGDPrefixSumEachBag + bagId * bagManager.m_numFeaValue;
	float_point *pTempHessSum = bagManager.m_pHessPrefixSumEachBag + bagId * bagManager.m_numFeaValue;
	thrust::inclusive_scan_by_key(thrust::system::cuda::par, pnKey_d, pnKey_d + bagManager.m_numFeaValue, pTempGDSum, pTempGDSum);//in place prefix sum
	thrust::inclusive_scan_by_key(thrust::system::cuda::par, pnKey_d, pnKey_d + bagManager.m_numFeaValue, pTempHessSum, pTempHessSum);

	cudaStreamSynchronize((*(cudaStream_t*)pStream));
	clock_t end_scan = clock();
	total_scan_t += (end_scan - start_scan);

//	cout << "compute gain" << endl;
	clock_t start_comp_gain = clock();
	//# of feature values that need to compute gains; the code below cannot be replaced by indexComp.m_totalNumFeaValue, due to some nodes becoming leaves.
	int numofDenseValue = indexComp.m_pFeaValueStartPosEachNode_dh[numofSNode - 1] + indexComp.m_pNumFeaValueEachNode_dh[numofSNode - 1];
	int blockSizeComGain;
	dim3 dimNumofBlockToComGain;
	conf.ConfKernel(numofDenseValue, blockSizeComGain, dimNumofBlockToComGain);
	ComputeGainDense<<<dimNumofBlockToComGain, blockSizeComGain, 0, (*(cudaStream_t*)pStream)>>>(
											bagManager.m_pSNodeStatEachBag + bagId * bagManager.m_maxNumSplittable,
											bagManager.m_pFvalueStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable,
											numofSNode,
											bagManager.m_pBuffIdVecEachBag + bagId * bagManager.m_maxNumSplittable,
											DeviceSplitter::m_lambda, bagManager.m_pGDPrefixSumEachBag + bagId * bagManager.m_numFeaValue,
											bagManager.m_pHessPrefixSumEachBag + bagId * bagManager.m_numFeaValue,
											bagManager.m_pDenseFValueEachBag + bagId * bagManager.m_numFeaValue, numofDenseValue,
											bagManager.m_pGainEachFvalueEachBag + bagId * bagManager.m_numFeaValue);
	cudaStreamSynchronize((*(cudaStream_t*)pStream));
	if(cudaGetLastError() != cudaSuccess){
		cerr << "error after ComputeGainDense" << endl;
		exit(-1);
	}

	//change the gain of the first feature value to 0
	int numFeaStartPos = indexComp.m_numFea * numofSNode;
//	printf("num of feature start positions=%d\n", numFeaStartPos);
	int blockSizeFirstGain;
	dim3 dimNumofBlockFirstGain;
	conf.ConfKernel(numFeaStartPos, blockSizeFirstGain, dimNumofBlockFirstGain);
	FirstFeaGain<<<dimNumofBlockFirstGain, blockSizeFirstGain, 0, (*(cudaStream_t*)pStream)>>>(
																bagManager.m_pEachFeaStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
																numFeaStartPos, bagManager.m_pGainEachFvalueEachBag + bagId * bagManager.m_numFeaValue);
	cudaStreamSynchronize((*(cudaStream_t*)pStream));
	if(cudaGetLastError() != cudaSuccess){
		cerr << "error after FirstFeaGain" << endl;
		exit(-1);
	}
	clock_t end_comp_gain = clock();
	total_com_gain_t += (end_comp_gain - start_comp_gain);

//	cout << "searching" << endl;
	clock_t start_search = clock();
	//compute # of blocks for each node
	int maxNumFeaValueOneNode = -1;
	for(int n = 0; n < numofSNode; n++)
	{//find the node with the max number of element
		if(maxNumFeaValueOneNode < indexComp.m_pNumFeaValueEachNode_dh[n])
			maxNumFeaValueOneNode = indexComp.m_pNumFeaValueEachNode_dh[n];
	}
	PROCESS_ERROR(maxNumFeaValueOneNode > 0);
	int blockSizeLocalBestGain;
	dim3 dimNumofBlockLocalBestGain;
	conf.ConfKernel(maxNumFeaValueOneNode, blockSizeLocalBestGain, dimNumofBlockLocalBestGain);
	PROCESS_ERROR(dimNumofBlockLocalBestGain.z == 1);
	dimNumofBlockLocalBestGain.z = numofSNode;//each node per super block
	int numBlockPerNode = dimNumofBlockLocalBestGain.x * dimNumofBlockLocalBestGain.y;
	//find the block level best gain for each node
	PickLocalBestSplitEachNode<<<dimNumofBlockLocalBestGain, blockSizeLocalBestGain, 0, (*(cudaStream_t*)pStream)>>>(
								bagManager.m_pNumFvalueEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable,
								bagManager.m_pFvalueStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable,
								bagManager.m_pGainEachFvalueEachBag + bagId * bagManager.m_numFeaValue,
								bagManager.m_pfLocalBestGainEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_maxNumofBlockPerNode,
								bagManager.m_pnLocalBestGainKeyEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_maxNumofBlockPerNode);
	cudaStreamSynchronize((*(cudaStream_t*)pStream));

	if(cudaGetLastError() != cudaSuccess){
		cerr << "error after PickLocalBestSplitEachNode" << endl;
		exit(-1);
	}

	//find the global best gain for each node
	if(numBlockPerNode > 1){
		int blockSizeBestGain;
		dim3 dimNumofBlockDummy;
		conf.ConfKernel(numBlockPerNode, blockSizeBestGain, dimNumofBlockDummy);
		PickGlobalBestSplitEachNode<<<numofSNode, blockSizeBestGain, 0, (*(cudaStream_t*)pStream)>>>(
									bagManager.m_pfLocalBestGainEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_maxNumofBlockPerNode,
									bagManager.m_pnLocalBestGainKeyEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_maxNumofBlockPerNode,
									bagManager.m_pfGlobalBestGainEachBag_d + bagId * bagManager.m_maxNumSplittable,
									bagManager.m_pnGlobalBestGainKeyEachBag_d + bagId * bagManager.m_maxNumSplittable,
								    numBlockPerNode, numofSNode);
		cudaStreamSynchronize((*(cudaStream_t*)pStream));
		if(cudaGetLastError() != cudaSuccess){
			cerr << "error after PickGlobalBestSplitEachNode" << endl;
			exit(-1);
		}
	}
	else{//local best fea is the global best fea
		manager.MemcpyDeviceToDeviceAsync(bagManager.m_pfLocalBestGainEachBag_d + bagId * bagManager.m_maxNumSplittable,
										bagManager.m_pfGlobalBestGainEachBag_d + bagId * bagManager.m_maxNumSplittable,
										sizeof(float_point) * numofSNode, pStream);
		manager.MemcpyDeviceToDeviceAsync(bagManager.m_pnLocalBestGainKeyEachBag_d + bagId * bagManager.m_maxNumSplittable,
											bagManager.m_pnGlobalBestGainKeyEachBag_d + bagId * bagManager.m_maxNumSplittable,
											sizeof(int) * numofSNode, pStream);
	}

	cudaStreamSynchronize((*(cudaStream_t*)pStream));
	clock_t end_search = clock();
	total_search_t += end_search - start_search;

//	cout << "construct split point" << endl;
	//construct split points; memset for split points
	manager.MemcpyHostToDeviceAsync(manager.m_pBestPointHost, bagManager.m_pBestSplitPointEachBag + bagId * bagManager.m_maxNumSplittable,
									sizeof(SplitPoint) * bagManager.m_maxNumSplittable, pStream);
	FindSplitInfo<<<1, numofSNode, 0, (*(cudaStream_t*)pStream)>>>(
									 bagManager.m_pEachFeaStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
									 bagManager.m_pEachFeaLenEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea,
									 bagManager.m_pDenseFValueEachBag + bagId * bagManager.m_numFeaValue,
									 bagManager.m_pfGlobalBestGainEachBag_d + bagId * bagManager.m_maxNumSplittable,
									 bagManager.m_pnGlobalBestGainKeyEachBag_d + bagId * bagManager.m_maxNumSplittable,
				  	  	  	  	  	 bagManager.m_pBuffIdVecEachBag + bagId * bagManager.m_maxNumSplittable, nNumofFeature,
				  	  	  	  	  	 bagManager.m_pSNodeStatEachBag + bagId * bagManager.m_maxNumSplittable,
				  	  	  	  	  	 bagManager.m_pGDPrefixSumEachBag + bagId * bagManager.m_numFeaValue,
				  	  	  	  	  	 bagManager.m_pHessPrefixSumEachBag + bagId * bagManager.m_numFeaValue,
				  	  	  	  	  	 bagManager.m_pBestSplitPointEachBag + bagId * bagManager.m_maxNumSplittable,
				  	  	  	  	  	 bagManager.m_pRChildStatEachBag + bagId * bagManager.m_maxNumSplittable,
				  	  	  	  	  	 bagManager.m_pLChildStatEachBag + bagId * bagManager.m_maxNumSplittable);
	cudaStreamSynchronize((*(cudaStream_t*)pStream));
//	cout << "Done find split" << endl;
}
