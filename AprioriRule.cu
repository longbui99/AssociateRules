#include "AprioriRule.h"
#include <thrust/device_vector.h>

AprioriRule::~AprioriRule() {
	cudaFree(_transactions_);
	cudaFree(_lCount_);
}
AprioriRule::AprioriRule(vector<vector<int>> _transactions, vector<int> _product, int tPeerB, int Cores, long double _minSp, long double _minConfi)
{
	startTime = clock();
	Step = 0;
	minSuport = _minSp;
	minConfin = _minConfi;
	Product = _product;
	defineThread = tPeerB;
	defineCores = Cores -1;
	peerSize = _product.size();
	frequentItemsets.push_back({ {} });
	tranSize = _transactions.size();

	int *tempTrans = new int[peerSize*tranSize];
	_countC = new int[tranSize];
	for (int i = 0; i < tranSize; i++) {
		// Parallel here
		_countC[i] = 0;
		for (int j = 0; j < peerSize; j++) {
			tempTrans[i*peerSize + j] = _transactions[i][j];
		}
	}
	cudaMalloc(&_transactions_, sizeof(int)*(peerSize*tranSize));
	cudaMalloc(&_lCount_, sizeof(int)*tranSize);
	cudaMemcpy(_transactions_, tempTrans, sizeof(int)*(peerSize*tranSize), cudaMemcpyHostToDevice);
	cudaMemcpy(_lCount_, _countC, sizeof(int)*(tranSize), cudaMemcpyHostToDevice);

	printf("%f\tLoad Data\n", clock() - startTime);

	delete tempTrans; tempTrans = NULL;
}
vector<tuple<vector<int>, vector<int>, long double, long double>> AprioriRule::getResult()
{
	return AprioriRules;
}
void AprioriRule::Process()
{
	for (auto i = Product.begin(); i != Product.end(); i++)
		C.push_back(vector<int>(1, *i));
	Step++;
	L = generateNewL();
	frequentItemsets.push_back(L);

	while (true)
	{
		printf("--Step %d -> %f\n", Step, clock() - startTime);
		C = generateNextC();
		if (C.size() == 0)
			break;
		Step++;
		L = generateNewL();

		frequentItemsets.push_back(L);
	}
	printf("Start check frequent Itemset %f\n", clock() - startTime);
	int fSize = frequentItemsets.size();
	int peer = fSize / (defineCores);
	thread *mThread = new thread[defineCores];
	for (int i = 0; i < defineCores; i++) {
		mThread[i] = thread(&AprioriRule::parallelFrequent, this, i*peer, peer);
	}
	int mod = fSize % (defineCores);
	if (mod != 0) {
		parallelFrequent((defineCores)*peer, mod);
	}
	for (int i = 0; i < defineCores; i++) {
		mThread[i].join();
	}
}

void AprioriRule::parallelFrequent(int start, int loop)
{
	loop = start + loop;
	for (int i = start; i < loop; i++) {
		// Parallel here
		for (auto &items : frequentItemsets[i])
		{
			generateAssociationRule(items, {}, {}, 0, minConfin);
		}
	}
}

void AprioriRule::generateAssociationRule(vector<int> items, vector<int> X, vector<int> Y, int index, long double minConfi) {
	if (index == items.size()) {
		if (X.size() == 0 || Y.size() == 0) return;
		long double XYsupport = getSupport(getIndex(items));
		long double Xsupport = getSupport(getIndex(X));

		if (Xsupport == 0) return;

		long double support = (long double)XYsupport;
		long double confidence = (long double)XYsupport / Xsupport * 100.0;
		if (confidence >= minConfi)
			AprioriRules.push_back({ X, Y, support, confidence });
		return;
	}

	X.push_back(items[index]);
	generateAssociationRule(items, X, Y, index + 1, minConfi);
	X.pop_back();
	Y.push_back(items[index]);
	generateAssociationRule(items, X, Y, index + 1, minConfi);
}

void AprioriRule::generateCParallel1(int start, int loop, int Lsize, vector<vector<int>>& temp)
{
	loop = start + loop;
	for (int i = start; i < loop; i++) {
		for (int j = i + 1; j < Lsize; j++) {
			int k;
			for (k = 0; k < Step - 1; k++)
				if (L[i][k] != L[j][k]) break;
			if (k == Step - 1) {
				vector<int> ret;
				for (int h = 0; h < Step - 1; h++)
					ret.push_back(L[i][h]);
				int f = L[i][Step - 1];
				int s = L[j][Step - 1];
				if (f > s) swap(f, s);
				Block.lock();
				ret.push_back(f), ret.push_back(s);
				temp.push_back(ret);
				Block.unlock();
			}
		}
	}
}

void AprioriRule::generateCParallel2(int start, int loop, set<vector<int>> LSet, vector<vector<int>>& temps, vector<vector<int>> temp)
{
	loop = start + loop;
	for (int l = start; l < loop; l++) {
		//MAYBE
		int i, size = temp[l].size();
		for (i = 0; i < size; i++) {
			vector<int> tmp = temp[l];
			tmp.erase(tmp.begin() + i);
			if (LSet.find(tmp) == LSet.end())
				break;
		}
		if (i == size) {
			Block.lock();
			temps.push_back(temp[l]);
			Block.unlock();
		}
	}
}
vector<vector<int>> AprioriRule::generateNextC() {
	printf("---Generate C:\t%f \t->", clock() - startTime);
	vector<vector<int>> temp;
	int Lsize = L.size();
	int peer = Lsize / (defineCores);
	thread *mThread = new thread[defineCores];
	for (int i = 0; i < defineCores; i++) {
		mThread[i] = thread(&AprioriRule::generateCParallel1, this, i*peer, peer, Lsize, ref(temp));
	}
	int mod = Lsize % (defineCores);
	if (mod != 0) {
		generateCParallel1((defineCores)*peer, mod, Lsize, ref(temp));
	}
	for (int i = 0; i < defineCores; i++) {
		mThread[i].join();
	}
	vector<vector<int>> temps;
	set<vector<int>> LSet;
	for (auto&row : L)
		LSet.insert(row);

	int Tsize = temp.size();
	peer = Tsize / (defineCores);
	
	for (int i = 0; i < defineCores; i++) {
		mThread[i] = thread(&AprioriRule::generateCParallel2, this,i*peer,peer, LSet, ref(temps), temp);
	}
	mod = Tsize % (defineCores);
	if (mod != 0) {
		generateCParallel2((defineCores)*peer, mod, LSet, ref(temps), temp);
	}
	for (int i = 0; i < defineCores; i++) {
		mThread[i].join();
	}
	printf("%f\n", clock() - startTime);
	return temps;
}
vector<vector<int>> AprioriRule::generateNewL() {
	printf("---Generate L: %f \t ->", clock() - startTime);
	vector<vector<int>> ret;
	for (auto&row : C) {
		long double sp = getSupport(getIndex(row));
		if (sp < minSuport) continue;
		ret.push_back(row);
	}
	printf("%f\n", clock() - startTime);
	return ret;
}

vector<int> AprioriRule::getIndex(vector<int> row) {
	vector<int> temp;

	for (int i = 0, j = 0; j < row.size(); i++) {
		if (Product[i] == row[j]) {
			temp.push_back(i);
			j++;
		}
	}
	return temp;
}


__global__ void ItemSupport(int *count_, int* _transactions_, int* item, int itemSize, int peerSize) {
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	bool boo;
	boo = true;
	for (int i = 0; i < itemSize; i++) {
		if (_transactions_[peerSize*(index)+item[i]] == 0) {
			boo = false;
			break;
		}
	}
	if (boo) {
		count_[index] = 1;
	}
	else {
		count_[index] = 0;
	}
}

long double AprioriRule::getSupport(vector<int> item) {
	int count = 0;
	int *item_, itemSize = item.size();
	cudaMalloc(&item_, sizeof(int)*itemSize);
	cudaMemcpy(item_, item.data(), sizeof(int)*itemSize, cudaMemcpyHostToDevice);
	if (tranSize < defineThread) {
		ItemSupport << <1, tranSize >> > (_lCount_, _transactions_, item_, itemSize, peerSize);
	}
	else {
		ItemSupport << <tranSize / defineThread, defineThread >> > (_lCount_, _transactions_, item_, itemSize, peerSize);
	}
	cudaFree(item_);

	cudaMemcpy(_countC, _lCount_, sizeof(int)*tranSize, cudaMemcpyDeviceToHost);
	for (int i = 0; i < tranSize; i++) {
		if (_countC[i] == 1) count++;
	}
	return (long double)count / tranSize * 100;
}