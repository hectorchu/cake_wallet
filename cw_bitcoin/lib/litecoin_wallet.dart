import 'dart:async';
import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:cw_bitcoin/bitcoin_mnemonic.dart';
import 'package:cw_bitcoin/bitcoin_transaction_priority.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/sync_status.dart';
import 'package:cw_core/unspent_coins_info.dart';
import 'package:cw_bitcoin/litecoin_wallet_addresses.dart';
import 'package:cw_core/transaction_priority.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:mobx/mobx.dart';
import 'package:cw_core/wallet_info.dart';
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
  }) : super(
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
      network: network,
    );
    autorun((_) {
      this.walletAddresses.isEnabledAutoGenerateSubaddress = this.isEnabledAutoGenerateSubaddress;
    });
  }

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

  @action
  @override
  Future<void> startSync() async {
    await super.startSync();
    final stub = CwMweb.stub();
    Timer.periodic(
      const Duration(milliseconds: 1500), (timer) async {
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
        }
      });
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
}
