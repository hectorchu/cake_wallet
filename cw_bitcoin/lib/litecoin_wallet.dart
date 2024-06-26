import 'dart:async';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:cw_bitcoin/bitcoin_mnemonic.dart';
import 'package:cw_bitcoin/bitcoin_transaction_priority.dart';
import 'package:cw_bitcoin/bitcoin_unspent.dart';
import 'package:cw_bitcoin/electrum_transaction_info.dart';
import 'package:cw_bitcoin/pending_bitcoin_transaction.dart';
import 'package:cw_bitcoin/utils.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/transaction_direction.dart';
import 'package:cw_core/unspent_coins_info.dart';
import 'package:cw_bitcoin/litecoin_wallet_addresses.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:mobx/mobx.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_bitcoin/electrum_wallet_snapshot.dart';
import 'package:cw_bitcoin/electrum_wallet.dart';
import 'package:cw_bitcoin/bitcoin_address_record.dart';
import 'package:cw_bitcoin/electrum_balance.dart';
import 'package:cw_bitcoin/litecoin_network.dart';
import 'package:cw_mweb/cw_mweb.dart';
import 'package:cw_mweb/mwebd.pb.dart';
import 'package:bitcoin_flutter/bitcoin_flutter.dart' as bitcoin;

part 'litecoin_wallet.g.dart';

class LitecoinWallet = LitecoinWalletBase with _$LitecoinWallet;

abstract class LitecoinWalletBase extends ElectrumWallet with Store {
  LitecoinWalletBase({
    required String mnemonic,
    required String password,
    required WalletInfo walletInfo,
    required Box<UnspentCoinsInfo> unspentCoinsInfo,
    required Uint8List seedBytes,
    String? addressPageType,
    List<BitcoinAddressRecord>? initialAddresses,
    ElectrumBalance? initialBalance,
    Map<String, int>? initialRegularAddressIndex,
    Map<String, int>? initialChangeAddressIndex,
  }) : mwebHd = bitcoin.HDWallet.fromSeed(seedBytes,
            network: litecoinNetwork).derivePath("m/1000'"),
       super(
            mnemonic: mnemonic,
            password: password,
            walletInfo: walletInfo,
            unspentCoinsInfo: unspentCoinsInfo,
            networkType: litecoinNetwork,
            initialAddresses: initialAddresses,
            initialBalance: initialBalance,
            seedBytes: seedBytes,
            currency: CryptoCurrency.ltc) {
    walletAddresses = LitecoinWalletAddresses(
      walletInfo,
      electrumClient: electrumClient,
      initialAddresses: initialAddresses,
      initialRegularAddressIndex: initialRegularAddressIndex,
      initialChangeAddressIndex: initialChangeAddressIndex,
      mainHd: hd,
      sideHd: bitcoin.HDWallet.fromSeed(seedBytes, network: networkType).derivePath("m/0'/1"),
      mwebHd: mwebHd,
      network: network,
    );
    autorun((_) {
      this.walletAddresses.isEnabledAutoGenerateSubaddress = this.isEnabledAutoGenerateSubaddress;
    });
  }

  final bitcoin.HDWallet mwebHd;

  static Future<LitecoinWallet> create(
      {required String mnemonic,
      required String password,
      required WalletInfo walletInfo,
      required Box<UnspentCoinsInfo> unspentCoinsInfo,
      String? addressPageType,
      List<BitcoinAddressRecord>? initialAddresses,
      ElectrumBalance? initialBalance,
      Map<String, int>? initialRegularAddressIndex,
      Map<String, int>? initialChangeAddressIndex}) async {
    return LitecoinWallet(
      mnemonic: mnemonic,
      password: password,
      walletInfo: walletInfo,
      unspentCoinsInfo: unspentCoinsInfo,
      initialAddresses: initialAddresses,
      initialBalance: initialBalance,
      seedBytes: await mnemonicToSeedBytes(mnemonic),
      initialRegularAddressIndex: initialRegularAddressIndex,
      initialChangeAddressIndex: initialChangeAddressIndex,
      addressPageType: addressPageType,
    );
  }

  static Future<LitecoinWallet> open({
    required String name,
    required WalletInfo walletInfo,
    required Box<UnspentCoinsInfo> unspentCoinsInfo,
    required String password,
  }) async {
    final snp =
        await ElectrumWalletSnapshot.load(name, walletInfo.type, password, LitecoinNetwork.mainnet);
    return LitecoinWallet(
      mnemonic: snp.mnemonic,
      password: password,
      walletInfo: walletInfo,
      unspentCoinsInfo: unspentCoinsInfo,
      initialAddresses: snp.addresses,
      initialBalance: snp.balance,
      seedBytes: await mnemonicToSeedBytes(snp.mnemonic),
      initialRegularAddressIndex: snp.regularAddressIndex,
      initialChangeAddressIndex: snp.changeAddressIndex,
      addressPageType: snp.addressPageType,
    );
  }

  int mwebUtxosHeight = 0;

  @action
  @override
  Future<void> startSync() async {
    await super.startSync();
    final stub = await CwMweb.stub();
    Timer.periodic(
      const Duration(milliseconds: 1500), (timer) async {
        if (syncStatus is FailedSyncStatus) return;
        final height = await electrumClient.getCurrentBlockChainTip() ?? 0;
        final resp = await stub.status(StatusRequest());
        if (resp.blockHeaderHeight < height) {
          int h = resp.blockHeaderHeight;
          syncStatus = SyncingSyncStatus(height - h, h / height);
        } else if (resp.mwebHeaderHeight < height) {
          int h = resp.mwebHeaderHeight;
          syncStatus = SyncingSyncStatus(height - h, h / height);
        } else if (resp.mwebUtxosHeight < height) {
          syncStatus = SyncingSyncStatus(1, 0.999);
        } else {
          syncStatus = SyncedSyncStatus();
          if (resp.mwebUtxosHeight > mwebUtxosHeight) {
            mwebUtxosHeight = resp.mwebUtxosHeight;
            await checkMwebUtxosSpent();
            for (final transaction in transactionHistory.transactions.values) {
              if (transaction.isPending) continue;
              final confirmations = mwebUtxosHeight - transaction.height + 1;
              if (transaction.confirmations == confirmations) continue;
              transaction.confirmations = confirmations;
              transactionHistory.addOne(transaction);
            }
            await transactionHistory.save();
          }
        }
      });
    processMwebUtxos();
  }

  final Map<String, Utxo> mwebUtxos = {};

  Future<void> processMwebUtxos() async {
    final stub = await CwMweb.stub();
    final scanSecret = mwebHd.derive(0x80000000).privKey!;
    final req = UtxosRequest(scanSecret: hex.decode(scanSecret));
    var initDone = false;
    await for (var utxo in stub.utxos(req)) {
      if (utxo.address.isEmpty) {
        await updateUnspent();
        await updateBalance();
        initDone = true;
      }
      final mwebAddrs = (walletAddresses as LitecoinWalletAddresses).mwebAddrs;
      if (!mwebAddrs.contains(utxo.address)) continue;
      mwebUtxos[utxo.outputId] = utxo;

      final status = await stub.status(StatusRequest());
      var date = DateTime.now();
      var confirmations = 0;
      if (utxo.height > 0) {
        date = DateTime.fromMillisecondsSinceEpoch(utxo.blockTime * 1000);
        confirmations = status.blockHeaderHeight - utxo.height + 1;
      }
      var tx = transactionHistory.transactions.values.firstWhereOrNull(
          (tx) => tx.outputAddresses?.contains(utxo.outputId) ?? false);
      if (tx == null)
        tx = ElectrumTransactionInfo(WalletType.litecoin,
          id: utxo.outputId, height: utxo.height,
          amount: utxo.value.toInt(), fee: 0,
          direction: TransactionDirection.incoming,
          isPending: utxo.height == 0,
          date: date, confirmations: confirmations,
          inputAddresses: [], outputAddresses: [utxo.outputId]);
      tx.height = utxo.height;
      tx.isPending = utxo.height == 0;
      tx.confirmations = confirmations;
      var isNew = transactionHistory.transactions[tx.id] == null;
      if (!(tx.outputAddresses?.contains(utxo.address) ?? false)) {
        tx.outputAddresses?.add(utxo.address);
        isNew = true;
      }
      if (isNew) {
        final addressRecord = walletAddresses.allAddresses.firstWhere(
            (addressRecord) => addressRecord.address == utxo.address);
        if (!(tx.inputAddresses?.contains(utxo.address) ?? false))
          addressRecord.txCount++;
        addressRecord.balance += utxo.value.toInt();
        addressRecord.setAsUsed();
      }
      transactionHistory.addOne(tx);
      if (initDone) {
        await updateUnspent();
        await updateBalance();
      }
    }
  }

  Future<void> checkMwebUtxosSpent() async {
    while ((await Future.wait(transactionHistory.transactions.values
        .where((tx) => tx.direction == TransactionDirection.outgoing && tx.isPending)
        .map(checkPendingTransaction))).any((x) => x));
    final outputIds = mwebUtxos.values
        .where((utxo) => utxo.height > 0)
        .map((utxo) => utxo.outputId).toList();
    final stub = await CwMweb.stub();
    final resp = await stub.spent(SpentRequest(outputId: outputIds));
    final spent = resp.outputId;
    if (spent.isEmpty) return;
    final status = await stub.status(StatusRequest());
    final height = await electrumClient.getCurrentBlockChainTip();
    if (height == null || status.blockHeaderHeight != height) return;
    if (status.mwebUtxosHeight != height) return;
    int amount = 0;
    Set<String> inputAddresses = {};
    var output = AccumulatorSink<Digest>();
    var input = sha256.startChunkedConversion(output);
    for (final outputId in spent) {
      final utxo = mwebUtxos[outputId];
      if (utxo == null) continue;
      final addressRecord = walletAddresses.allAddresses.firstWhere(
          (addressRecord) => addressRecord.address == utxo.address);
      if (!inputAddresses.contains(utxo.address))
        addressRecord.txCount++;
      addressRecord.balance -= utxo.value.toInt();
      amount += utxo.value.toInt();
      inputAddresses.add(utxo.address);
      mwebUtxos.remove(outputId);
      input.add(hex.decode(outputId));
    }
    if (inputAddresses.isEmpty) return;
    input.close();
    var digest = output.events.single;
    final tx = ElectrumTransactionInfo(WalletType.litecoin,
      id: digest.toString(), height: height,
      amount: amount, fee: 0,
      direction: TransactionDirection.outgoing,
      isPending: false,
      date: DateTime.fromMillisecondsSinceEpoch(status.blockTime * 1000),
      confirmations: 1,
      inputAddresses: inputAddresses.toList(),
      outputAddresses: []);
    transactionHistory.addOne(tx);
    await transactionHistory.save();
  }

  Future<bool> checkPendingTransaction(ElectrumTransactionInfo tx) async {
    if (!tx.isPending) return false;
    final outputId = <String>[], target = <String>{};
    final isHash = RegExp(r'^[a-f0-9]{64}$').hasMatch;
    final spendingOutputIds = tx.inputAddresses?.where(isHash) ?? [];
    final payingToOutputIds = tx.outputAddresses?.where(isHash) ?? [];
    outputId.addAll(spendingOutputIds);
    outputId.addAll(payingToOutputIds);
    target.addAll(spendingOutputIds);
    for (final outputId in payingToOutputIds) {
      final spendingTx = transactionHistory.transactions.values.firstWhereOrNull(
          (tx) => tx.inputAddresses?.contains(outputId) ?? false);
      if (spendingTx != null && !spendingTx.isPending)
        target.add(outputId);
    }
    if (outputId.isEmpty) return false;
    final stub = await CwMweb.stub();
    final resp = await stub.spent(SpentRequest(outputId: outputId));
    if (!setEquals(resp.outputId.toSet(), target)) return false;
    final status = await stub.status(StatusRequest());
    if (!tx.isPending) return false;
    tx.height = status.mwebUtxosHeight;
    tx.confirmations = 1;
    tx.isPending = false;
    await transactionHistory.save();
    return true;
  }

  @override
  Future<void> updateUnspentCoins() async {
    await super.updateUnspentCoins();
    await checkMwebUtxosSpent();
    final mwebAddrs = (walletAddresses as LitecoinWalletAddresses).mwebAddrs;
    mwebUtxos.forEach((outputId, utxo) {
      final addressRecord = walletAddresses.allAddresses.firstWhere(
          (addressRecord) => addressRecord.address == utxo.address);
      final unspent = BitcoinUnspent(addressRecord, outputId,
          utxo.value.toInt(), mwebAddrs.indexOf(utxo.address));
      if (unspent.vout == 0) unspent.isChange = true;
      unspentCoins.add(unspent);
    });
  }

  @override
  Future<ElectrumBalance> fetchBalances() async {
    final balance = await super.fetchBalances();
    var confirmed = balance.confirmed;
    var unconfirmed = balance.unconfirmed;
    mwebUtxos.values.forEach((utxo) {
      if (utxo.height > 0)
        confirmed += utxo.value.toInt();
      else
        unconfirmed += utxo.value.toInt();
    });
    return ElectrumBalance(confirmed: confirmed,
        unconfirmed: unconfirmed, frozen: balance.frozen);
  }

  @override
  int feeRate(TransactionPriority priority) {
    if (priority is LitecoinTransactionPriority) {
      switch (priority) {
        case LitecoinTransactionPriority.slow:
          return 1;
        case LitecoinTransactionPriority.medium:
          return 2;
        case LitecoinTransactionPriority.fast:
          return 3;
      }
    }

    return 0;
  }

  @override
  Future<int> calcFee({
      required List<UtxoWithAddress> utxos,
      required List<BitcoinBaseOutput> outputs,
      required BasedUtxoNetwork network,
      String? memo,
      required int feeRate}) async {

    final spendsMweb = utxos.any((utxo) => utxo.utxo.scriptType == SegwitAddresType.mweb);
    final paysToMweb = outputs.any((output) =>
        output.toOutput.scriptPubKey.getAddressType() == SegwitAddresType.mweb);
    if (!spendsMweb && !paysToMweb) {
      return await super.calcFee(utxos: utxos, outputs: outputs,
          network: network, memo: memo, feeRate: feeRate);
    }
    if (outputs.length == 1 && outputs[0].toOutput.amount == BigInt.zero) {
      outputs = [BitcoinScriptOutput(
          script: outputs[0].toOutput.scriptPubKey,
          value: utxos.sumOfUtxosValue())];
    }
    final preOutputSum = outputs.fold<BigInt>(BigInt.zero,
        (acc, output) => acc + output.toOutput.amount);
    final fee = utxos.sumOfUtxosValue() - preOutputSum;
    final txb = BitcoinTransactionBuilder(utxos: utxos,
        outputs: outputs, fee: fee, network: network);
    final stub = await CwMweb.stub();
    final resp = await stub.create(CreateRequest(
        rawTx: txb.buildTransaction((a, b, c, d) => '').toBytes(),
        scanSecret: hex.decode(mwebHd.derive(0x80000000).privKey!),
        spendSecret: hex.decode(mwebHd.derive(0x80000001).privKey!),
        feeRatePerKb: Int64(feeRate * 1000),
        dryRun: true));
    final tx = BtcTransaction.fromRaw(hex.encode(resp.rawTx));
    final posUtxos = utxos.where((utxo) => tx.inputs.any((input) =>
        input.txId == utxo.utxo.txHash && input.txIndex == utxo.utxo.vout)).toList();
    final posOutputSum = tx.outputs.fold<int>(0, (acc, output) => acc + output.amount.toInt());
    final mwebInputSum = utxos.sumOfUtxosValue() - posUtxos.sumOfUtxosValue();
    final expectedPegin = max(0, (preOutputSum - mwebInputSum).toInt());
    var feeIncrease = posOutputSum - expectedPegin;
    if (expectedPegin > 0 && fee == BigInt.zero) {
      feeIncrease += await super.calcFee(utxos: posUtxos, outputs: tx.outputs.map((output) =>
          BitcoinScriptOutput(script: output.scriptPubKey, value: output.amount)).toList(),
          network: network, memo: memo, feeRate: feeRate) + feeRate * 41;
    }
    return fee.toInt() + feeIncrease;
  }

  @override
  Future<PendingTransaction> createTransaction(Object credentials) async {
    final tx = await super.createTransaction(credentials) as PendingBitcoinTransaction;
    final stub = await CwMweb.stub();
    final resp = await stub.create(CreateRequest(
        rawTx: hex.decode(tx.hex),
        scanSecret: hex.decode(mwebHd.derive(0x80000000).privKey!),
        spendSecret: hex.decode(mwebHd.derive(0x80000001).privKey!),
        feeRatePerKb: Int64.parseInt(tx.feeRate) * 1000));
    final tx2 = BtcTransaction.fromRaw(hex.encode(resp.rawTx));
    tx.hexOverride = tx2.copyWith(witnesses: tx2.inputs.asMap().entries.map((e) {
      final utxo = unspentCoins.firstWhere((utxo) =>
          utxo.hash == e.value.txId && utxo.vout == e.value.txIndex);
      final key = generateECPrivate(hd: utxo.bitcoinAddressRecord.isHidden ?
          walletAddresses.sideHd : walletAddresses.mainHd,
          index: utxo.bitcoinAddressRecord.index, network: network);
      final digest = tx2.getTransactionSegwitDigit(txInIndex: e.key,
          script: key.getPublic().toP2pkhAddress().toScriptPubKey(),
          amount: BigInt.from(utxo.value));
      return TxWitnessInput(stack: [key.signInput(digest), key.getPublic().toHex()]);
    }).toList()).toHex();
    tx.outputs = resp.outputId;
    return tx..addListener((transaction) async {
      final addresses = <String>{};
      transaction.inputAddresses?.forEach((id) {
        final utxo = mwebUtxos.remove(id);
        if (utxo == null) return;
        final addressRecord = walletAddresses.allAddresses.firstWhere(
            (addressRecord) => addressRecord.address == utxo.address);
        if (!addresses.contains(utxo.address)) {
          addressRecord.txCount++;
          addresses.add(utxo.address);
        }
        addressRecord.balance -= utxo.value.toInt();
      });
      transaction.inputAddresses?.addAll(addresses);
      transactionHistory.addOne(transaction);
      await updateUnspent();
      await updateBalance();
    });
  }
}
