import 'dart:async';
import 'dart:io';
import 'package:flare_flutter/flare_actor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kalium_wallet_flutter/appstate_container.dart';
import 'package:kalium_wallet_flutter/colors.dart';
import 'package:kalium_wallet_flutter/dimens.dart';
import 'package:kalium_wallet_flutter/model/list_model.dart';
import 'package:kalium_wallet_flutter/model/state_block.dart';
import 'package:kalium_wallet_flutter/model/db/contact.dart';
import 'package:kalium_wallet_flutter/model/db/kaliumdb.dart';
import 'package:kalium_wallet_flutter/network/account_service.dart';
import 'package:kalium_wallet_flutter/network/model/block_types.dart';
import 'package:kalium_wallet_flutter/network/model/response/account_history_response.dart';
import 'package:kalium_wallet_flutter/network/model/response/account_history_response_item.dart';
import 'package:kalium_wallet_flutter/styles.dart';
import 'package:kalium_wallet_flutter/localization.dart';
import 'package:kalium_wallet_flutter/kalium_icons.dart';
import 'package:kalium_wallet_flutter/ui/contacts/add_contact.dart';
import 'package:kalium_wallet_flutter/ui/send/send_sheet.dart';
import 'package:kalium_wallet_flutter/ui/send/send_complete_sheet.dart';
import 'package:kalium_wallet_flutter/ui/receive/receive_sheet.dart';
import 'package:kalium_wallet_flutter/ui/settings/settings_sheet.dart';
import 'package:kalium_wallet_flutter/ui/widgets/buttons.dart';
import 'package:kalium_wallet_flutter/ui/widgets/kalium_drawer.dart';
import 'package:kalium_wallet_flutter/ui/widgets/kalium_scaffold.dart';
import 'package:kalium_wallet_flutter/ui/widgets/sheets.dart';
import 'package:kalium_wallet_flutter/ui/util/ui_util.dart';
import 'package:kalium_wallet_flutter/util/sharedprefsutil.dart';
import 'package:kalium_wallet_flutter/util/numberutil.dart';
import 'package:kalium_wallet_flutter/bus/rxbus.dart';

class KaliumHomePage extends StatefulWidget {
  @override
  _KaliumHomePageState createState() => _KaliumHomePageState();
}

class _KaliumHomePageState extends State<KaliumHomePage>
    with WidgetsBindingObserver {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  var _scaffoldKey = new GlobalKey<KaliumScaffoldState>();

  KaliumReceiveSheet receive = new KaliumReceiveSheet();

  // A separate unfortunate instance of this list, is a little unfortunate
  // but seems the only way to handle the animations
  ListModel<AccountHistoryResponseItem> _historyList;

  // monKey widget
  Widget _monKey;

  // List of contacts (Store it so we only have to query the DB once for transaction cards)
  List<Contact> _contacts = List();

  // Price conversion state (BTC, NANO, NONE)
  PriceConversion _priceConversion;
  TextStyle _convertedPriceStyle = KaliumStyles.TextStyleCurrencyAlt;

  // Timeeout for refresh
  StreamSubscription<dynamic> _refreshTimeout;

  Future<File> downloadOrRetrieveMonkey(String path) async {
    if (path != null) {
      if (await File(path).exists()) {
        return File(path);
      }
    }
    HttpClient httpClient = new HttpClient();
    String address = StateContainer.of(context).wallet.address;
    var request = await httpClient
        .getUrl(Uri.parse(KaliumLocalization.MONKEY_DOWNLOAD_URL + address));
    var response = await request.close();
    var bytes = await consolidateHttpClientResponseBytes(response);
    String dir = (await getApplicationDocumentsDirectory()).path;
    String fileName = '$dir/$address.png';
    File file = new File(fileName);
    await file.writeAsBytes(bytes);
    await SharedPrefsUtil.inst.setMonkeyLocation(fileName);
    return file;
  }

  @override
  void initState() {
    super.initState();
    _registerBus();
    _monKey = SizedBox();
    WidgetsBinding.instance.addObserver(this);
    SharedPrefsUtil.inst.getPriceConversion().then((result) {
      _priceConversion = result;
    });
    SharedPrefsUtil.inst.getMonkeyLocation().then((result) {
      downloadOrRetrieveMonkey(result).then((file) {
        if (file != null) {
          setState(() {
            _monKey = Image.file(file);
          });
        }
      });
    });
    _updateContacts();
  }

  void _updateContacts() {
    DBHelper().getContacts().then((contacts) {
      setState(() {
        _contacts = contacts;
      });
    });
  }

  void _registerBus() {
    RxBus.register<AccountHistoryResponse>(tag: RX_HISTORY_HOME_TAG)
        .listen((historyResponse) {
      diffAndUpdateHistoryList(historyResponse.history);
      if (_refreshTimeout != null) {
        _refreshTimeout.cancel();
      }
    });
    RxBus.register<StateBlock>(tag: RX_SEND_COMPLETE_TAG).listen((stateBlock) {
      // Route to send complete if received process response for send block
      if (stateBlock != null) {
        // Route to send complete
        String displayAmount =
            NumberUtil.getRawAsUsableString(stateBlock.sendAmount);
        DBHelper().getContactWithAddress(stateBlock.link).then((contact) {
          String contactName = contact == null ? null : contact.name;
          KaliumSendCompleteSheet(displayAmount, stateBlock.link, contactName)
              .mainBottomSheet(context);
          StateContainer.of(context).requestUpdate();
        });
      }
    });
    RxBus.register<StateBlock>(tag: RX_REP_CHANGED_TAG).listen((stateBlock) {
      if (stateBlock != null) {
        Navigator.of(context).popUntil(ModalRoute.withName('/home'));
        StateContainer.of(context).wallet.representative =
            stateBlock.representative;
        _scaffoldKey.currentState.showSnackBar(new SnackBar(
          content: new Text("Representative Changed Successfully",
              style: KaliumStyles.TextStyleSnackbar),
        ));
      }
    });
    RxBus.register<Contact>(tag: RX_CONTACT_MODIFIED_TAG).listen((contact) {
      _updateContacts();
    });
    RxBus.register<Contact>(tag: RX_CONTACT_ADDED_ALT_TAG).listen((contact) {
      _scaffoldKey.currentState.showSnackBar(new SnackBar(
        content: new Text("${contact.name} added to contacts.",
            style: KaliumStyles.TextStyleSnackbar),
      ));
    });
  }

  @override
  void dispose() {
    _destroyBus();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _destroyBus() {
    RxBus.destroy(tag: RX_HISTORY_HOME_TAG);
    RxBus.destroy(tag: RX_PROCESS_TAG);
    RxBus.destroy(tag: RX_CONTACT_MODIFIED_TAG);
    RxBus.destroy(tag: RX_CONTACT_ADDED_ALT_TAG);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle websocket connection when app is in background
    // terminate it to be eco-friendly
    switch (state) {
      case AppLifecycleState.paused:
        AccountService.reset(suspend: true);
        super.didChangeAppLifecycleState(state);
        break;
      case AppLifecycleState.resumed:
        AccountService.initCommunication(unsuspend: true);
        super.didChangeAppLifecycleState(state);
        break;
      default:
        super.didChangeAppLifecycleState(state);
        break;
    }
  }

  // Used to build list items that haven't been removed.
  Widget _buildItem(
      BuildContext context, int index, Animation<double> animation) {
    String displayName = _historyList[index].getShortString();
    _contacts.forEach((contact) {
      if (contact.address == _historyList[index].account) {
        displayName = contact.name;
      }
    });
    return _buildTransactionCard(
        _historyList[index], animation, displayName, context);
  }

  // Return widget for list
  Widget _getListWidget(BuildContext context) {
    if (StateContainer.of(context).wallet.historyLoading) {
      // Loading Animation
      return Center(
        child: Container(
          margin: EdgeInsets.all(MediaQuery.of(context).size.width * 0.1),
          //Widgth/Height ratio is needed because BoxFit is not working as expected
          width: double.infinity,
          height: MediaQuery.of(context).size.width,
          child: FlareActor("assets/loading_animation.flr",
              animation: "main", fit: BoxFit.contain),
        ),
      );
    } else if (StateContainer.of(context).wallet.history.length == 0) {
      return RefreshIndicator(
        child: ListView(
          padding: EdgeInsets.fromLTRB(0, 5.0, 0, 15.0),
          children: <Widget>[
            _buildWelcomeTransactionCard(),
            _buildDummyTransactionCard(
                "Sent", "A little", "to a random monkey", context),
            _buildDummyTransactionCard(
                "Received", "A lot of", "from a random monkey", context),
          ],
        ),
        onRefresh: _refresh,
      );
    }
    // Setup history list
    if (_historyList == null) {
      setState(() {
        _historyList = ListModel<AccountHistoryResponseItem>(
          listKey: _listKey,
          initialItems: StateContainer.of(context).wallet.history,
        );
      });
    }
    return RefreshIndicator(
      child: AnimatedList(
        key: _listKey,
        padding: EdgeInsets.fromLTRB(0, 5.0, 0, 15.0),
        initialItemCount: _historyList.length,
        itemBuilder: _buildItem,
      ),
      onRefresh: _refresh,
    );
  }

  // Refresh list
  Future<void> _refresh() async {
    StateContainer.of(context).requestUpdate();
    // TODO figure out how to cancel this future when the server responds with
    await Future.delayed(new Duration(seconds: 1), () {});
  }

  ///
  /// Because there's nothing convenient like DiffUtil, some manual logic
  /// to determine the differences between two lists and to add new items.
  ///
  /// Depends on == being overriden in the AccountHistoryResponseItem class
  ///
  /// Required to do it this way for the animation
  ///
  void diffAndUpdateHistoryList(List<AccountHistoryResponseItem> newList) {
    if (newList == null || newList.length == 0 || _historyList == null) return;
    var reversedNew = newList.reversed;
    var currentList = _historyList.items;

    reversedNew.forEach((item) {
      if (!currentList.contains(item)) {
        setState(() {
          _historyList.insertAtTop(item);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    drawerWidth() {
      if (MediaQuery.of(context).size.width < 375)
        return MediaQuery.of(context).size.width * 0.94;
      else
        return MediaQuery.of(context).size.width * 0.85;
    }

    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light
        .copyWith(statusBarIconBrightness: Brightness.light));
    return KaliumScaffold(
      key: _scaffoldKey,
      backgroundColor: KaliumColors.background,
      drawer: SizedBox(
        width: drawerWidth(),
        child: KaliumDrawer(
          child: SettingsSheet(),
        ),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          //Main Card
          _buildMainCard(context, _scaffoldKey),
          //Main Card End

          //Transactions Text
          Container(
            margin: EdgeInsets.fromLTRB(30.0, 20.0, 26.0, 0.0),
            child: Row(
              children: <Widget>[
                Text(
                  "TRANSACTIONS",
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: 14.0,
                    fontWeight: FontWeight.w100,
                    color: KaliumColors.text,
                  ),
                ),
              ],
            ),
          ), //Transactions Text End

          //Transactions List
          Expanded(
            child: Stack(
              children: <Widget>[
                _getListWidget(context),
                //List Top Gradient End
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    height: 10.0,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          KaliumColors.background00,
                          KaliumColors.background
                        ],
                        begin: Alignment(0.5, 1.0),
                        end: Alignment(0.5, -1.0),
                      ),
                    ),
                  ),
                ), // List Top Gradient End

                //List Bottom Gradient
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    height: 30.0,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          KaliumColors.background00,
                          KaliumColors.background
                        ],
                        begin: Alignment(0.5, -1),
                        end: Alignment(0.5, 0.5),
                      ),
                    ),
                  ),
                ), //List Bottom Gradient End
              ],
            ),
          ), //Transactions List End

          //Buttons Area
          Container(
            color: KaliumColors.background,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Container(
                    margin: EdgeInsets.fromLTRB(14.0, 0.0, 7.0,
                        MediaQuery.of(context).size.height * 0.035),
                    child: FlatButton(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(100.0)),
                      color: KaliumColors.primary,
                      child: Text('Receive',
                          textAlign: TextAlign.center,
                          style: KaliumStyles.TextStyleButtonPrimary),
                      padding:
                          EdgeInsets.symmetric(vertical: 14.0, horizontal: 20),
                      onPressed: () => receive.mainBottomSheet(context),
                      highlightColor: KaliumColors.background40,
                      splashColor: KaliumColors.background40,
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    margin: EdgeInsets.fromLTRB(7.0, 0.0, 14.0,
                        MediaQuery.of(context).size.height * 0.035),
                    child: FlatButton(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(100.0)),
                      color: KaliumColors.primary,
                      child: Text('Send',
                          textAlign: TextAlign.center,
                          style: KaliumStyles.TextStyleButtonPrimary),
                      padding:
                          EdgeInsets.symmetric(vertical: 14.0, horizontal: 20),
                      onPressed: () =>
                          KaliumSendSheet().mainBottomSheet(context),
                      highlightColor: KaliumColors.background40,
                      splashColor: KaliumColors.background40,
                    ),
                  ),
                ),
              ],
            ),
          ), //Buttons Area End
        ],
      ),
    );
  }

// Transaction Card/List Item
  Widget _buildTransactionCard(AccountHistoryResponseItem item,
      Animation<double> animation, String displayName, BuildContext context) {
    TransactionDetailsSheet transactionDetails =
        TransactionDetailsSheet(item.hash, item.account, displayName);
    String text;
    IconData icon;
    Color iconColor;
    if (item.type == BlockTypes.SEND) {
      text = "Sent";
      icon = KaliumIcons.sent;
      iconColor = KaliumColors.text60;
    } else {
      text = "Received";
      icon = KaliumIcons.received;
      iconColor = KaliumColors.primary60;
    }
    return SizeTransition(
      axis: Axis.vertical,
      axisAlignment: -1.0,
      sizeFactor: animation,
      child: Container(
        margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
        decoration: BoxDecoration(
          color: KaliumColors.backgroundDark,
          borderRadius: BorderRadius.circular(10.0),
        ),
        child: FlatButton(
          highlightColor: KaliumColors.text15,
          splashColor: KaliumColors.text15,
          color: KaliumColors.backgroundDark,
          padding: EdgeInsets.all(0.0),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
          onPressed: () => transactionDetails.mainBottomSheet(context),
          child: Center(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 14.0, horizontal: 20.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                          margin: EdgeInsets.only(right: 16.0),
                          child: Icon(icon, color: iconColor, size: 20)),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            text,
                            textAlign: TextAlign.left,
                            style: KaliumStyles.TextStyleTransactionType,
                          ),
                          RichText(
                            textAlign: TextAlign.left,
                            text: TextSpan(
                              text: '',
                              children: [
                                TextSpan(
                                  text: item.getFormattedAmount(),
                                  style:
                                      KaliumStyles.TextStyleTransactionAmount,
                                ),
                                TextSpan(
                                  text: " BAN",
                                  style: KaliumStyles.TextStyleTransactionUnit,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Text(
                    displayName,
                    textAlign: TextAlign.right,
                    style: KaliumStyles.TextStyleTransactionAddress,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  } //Transaction Card End

  // Dummy Transaction Card
  Widget _buildDummyTransactionCard(
      String type, String amount, String address, BuildContext context) {
    String text;
    IconData icon;
    Color iconColor;
    if (type == "Sent") {
      text = "Sent";
      icon = KaliumIcons.sent;
      iconColor = KaliumColors.text60;
    } else {
      text = "Received";
      icon = KaliumIcons.received;
      iconColor = KaliumColors.primary60;
    }
    return Container(
      margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
      decoration: BoxDecoration(
        color: KaliumColors.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
      ),
      child: FlatButton(
        onPressed: () {
          return null;
        },
        highlightColor: KaliumColors.text15,
        splashColor: KaliumColors.text15,
        color: KaliumColors.backgroundDark,
        padding: EdgeInsets.all(0.0),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
        child: Center(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 14.0, horizontal: 20.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                        margin: EdgeInsets.only(right: 16.0),
                        child: Icon(icon, color: iconColor, size: 20)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          text,
                          textAlign: TextAlign.left,
                          style: KaliumStyles.TextStyleTransactionType,
                        ),
                        RichText(
                          textAlign: TextAlign.left,
                          text: TextSpan(
                            text: '',
                            children: [
                              TextSpan(
                                text: amount,
                                style: KaliumStyles.TextStyleTransactionAmount,
                              ),
                              TextSpan(
                                text: " BAN",
                                style: KaliumStyles.TextStyleTransactionUnit,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Text(
                  address,
                  textAlign: TextAlign.right,
                  style: KaliumStyles.TextStyleTransactionAddress,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } //Dummy Transaction Card End

  // Welcome Card
  Widget _buildWelcomeTransactionCard() {
    return Container(
      margin: EdgeInsets.fromLTRB(14.0, 4.0, 14.0, 4.0),
      decoration: BoxDecoration(
        color: KaliumColors.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
      ),
      child: IntrinsicHeight(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Container(
              width: 7.0,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(10.0),
                    bottomLeft: Radius.circular(10.0)),
                color: KaliumColors.primary,
              ),
            ),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    vertical: 14.0, horizontal: 15.0),
                child: RichText(
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    text: '',
                    children: [
                      TextSpan(
                        text: "Welcome to Kalium. Once you receive ",
                        style: KaliumStyles.TextStyleTransactionWelcome,
                      ),
                      TextSpan(
                        text: "BANANO",
                        style: KaliumStyles.TextStyleTransactionWelcomePrimary,
                      ),
                      TextSpan(
                        text: ", transactions will show up like below.",
                        style: KaliumStyles.TextStyleTransactionWelcome,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              width: 7.0,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.only(
                    topRight: Radius.circular(10.0),
                    bottomRight: Radius.circular(10.0)),
                color: KaliumColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  } // Welcome Card End

  //Main Card
  Widget _buildMainCard(BuildContext context, _scaffoldKey) {
    return Container(
      decoration: BoxDecoration(
        color: KaliumColors.backgroundDark,
        borderRadius: BorderRadius.circular(10.0),
      ),
      margin: EdgeInsets.only(
          top: MediaQuery.of(context).size.height * 0.05,
          left: 14.0,
          right: 14.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Container(
            width: 90.0,
            height: 120.0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  margin: EdgeInsets.only(top: 5, left: 5),
                  height: 50,
                  width: 50,
                  child: FlatButton(
                      onPressed: () {
                        _scaffoldKey.currentState.openDrawer();
                      },
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(50.0)),
                      padding: EdgeInsets.all(0.0),
                      child: Icon(KaliumIcons.settings,
                          color: KaliumColors.text, size: 24)),
                ),
              ],
            ),
          ),
          _getBalanceWidget(context),
          Container(
            width: 90.0,
            height: 90.0,
            child: FlatButton(
                child: _monKey,
                padding: EdgeInsets.all(0.0),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(100.0)),
                onPressed: () {
                  Navigator.of(context).push(MonkeyOverlay(_monKey));
                }),
          ),
        ],
      ),
    );
  } //Main Card

  // Get balance display
  Widget _getBalanceWidget(BuildContext context) {
    if (StateContainer.of(context).wallet.loading) {
      return Container(
          child: Icon(KaliumIcons.bananologo,
              color: KaliumColors.primary, size: 40));
    }
    return Container(
      child: GestureDetector(
        onTap: () {
          if (_priceConversion == PriceConversion.BTC) {
            // Cycle to NANO price
            setState(() {
              _convertedPriceStyle = KaliumStyles.TextStyleCurrencyAlt;
              _priceConversion = PriceConversion.NANO;
            });
            SharedPrefsUtil.inst.setPriceConversion(PriceConversion.NANO);
          } else if (_priceConversion == PriceConversion.NANO) {
            // Hide prices
            setState(() {
              _convertedPriceStyle = KaliumStyles.TextStyleCurrencyAltHidden;
              _priceConversion = PriceConversion.NONE;
            });
            SharedPrefsUtil.inst.setPriceConversion(PriceConversion.NONE);
          } else {
            // Cycle to BTC price
            setState(() {
              _convertedPriceStyle = KaliumStyles.TextStyleCurrencyAlt;
              _priceConversion = PriceConversion.BTC;
            });
            SharedPrefsUtil.inst.setPriceConversion(PriceConversion.BTC);
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              margin: EdgeInsets.only(right: 5.0),
              child: Text(
                  StateContainer.of(context).wallet.getLocalCurrencyPrice(
                      locale: StateContainer.of(context).currencyLocale),
                  textAlign: TextAlign.center,
                  style: _convertedPriceStyle),
            ),
            Row(
              children: <Widget>[
                Container(
                    margin: EdgeInsets.only(right: 5.0),
                    child: Icon(KaliumIcons.bananocurrency,
                        color: KaliumColors.primary, size: 20)),
                Container(
                  margin: EdgeInsets.only(right: 15.0),
                  child: Text(
                      StateContainer.of(context)
                          .wallet
                          .getAccountBalanceDisplay(),
                      textAlign: TextAlign.center,
                      style: KaliumStyles.TextStyleCurrency),
                ),
              ],
            ),
            Row(
              children: <Widget>[
                Container(
                    child: Icon(
                        _priceConversion == PriceConversion.BTC
                            ? KaliumIcons.btc
                            : KaliumIcons.nanocurrency,
                        color: _priceConversion == PriceConversion.NONE
                            ? Colors.transparent
                            : KaliumColors.text60,
                        size: 14)),
                Text(
                    _priceConversion == PriceConversion.BTC
                        ? StateContainer.of(context).wallet.btcPrice
                        : StateContainer.of(context).wallet.nanoPrice,
                    textAlign: TextAlign.center,
                    style: _convertedPriceStyle),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TransactionDetailsSheet {
  String _hash;
  String _address;
  String _displayName;
  TransactionDetailsSheet(String hash, String address, String displayName)
      : _hash = hash,
        _address = address,
        _displayName = displayName;
  // Address copied items
  // Initial constants
  static const String _copyAddress = 'Copy Address';
  static const TextStyle _copyButtonStyleInitial =
      KaliumStyles.TextStyleButtonPrimary;
  static const Color _copyButtonColorInitial = KaliumColors.primary;
  // Current state references
  bool _addressCopied = false;
  // Timer reference so we can cancel repeated events
  Timer _addressCopiedTimer;

  mainBottomSheet(BuildContext context) {
    KaliumSheets.showKaliumHeightEightSheet(
        context: context,
        builder: (BuildContext context) {
          return StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
            return Container(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Column(
                    children: <Widget>[
                      // A stack for Copy Address and Add Contact buttons
                      Stack(
                        children: <Widget>[
                          // A row for Copy Address Button
                          Row(
                            children: <Widget>[
                              // TODO move copy address stuff to a re-usable builder function
                              Expanded(
                                child: Container(
                                  margin: EdgeInsets.fromLTRB(
                                      Dimens.BUTTON_TOP_EXCEPTION_DIMENS[0],
                                      Dimens.BUTTON_TOP_EXCEPTION_DIMENS[1],
                                      Dimens.BUTTON_TOP_EXCEPTION_DIMENS[2],
                                      Dimens.BUTTON_TOP_EXCEPTION_DIMENS[3]),
                                  // Copy Address Button
                                  child: FlatButton(
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(100.0)),
                                    color: _addressCopied
                                        ? KaliumColors.success
                                        : KaliumColors.primary,
                                    child: Text(
                                        _addressCopied
                                            ? "Address Copied"
                                            : "Copy Address",
                                        textAlign: TextAlign.center,
                                        style: _addressCopied
                                            ? KaliumStyles
                                                .TextStyleButtonPrimaryGreen
                                            : KaliumStyles
                                                .TextStyleButtonPrimary),
                                    padding: EdgeInsets.symmetric(
                                        vertical: 14.0, horizontal: 20),
                                    onPressed: () {
                                      Clipboard.setData(
                                          new ClipboardData(text: _address));
                                      setState(() {
                                        // Set copied style
                                        _addressCopied = true;
                                      });
                                      if (_addressCopiedTimer != null) {
                                        _addressCopiedTimer.cancel();
                                      }
                                      _addressCopiedTimer = new Timer(
                                          const Duration(milliseconds: 800),
                                          () {
                                        setState(() {
                                          _addressCopied = false;
                                        });
                                      });
                                    },
                                    highlightColor: KaliumColors.success30,
                                    splashColor: KaliumColors.successDark,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          // A row for Add Contact Button
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              Container(
                                margin: EdgeInsets.only(
                                    top: Dimens.BUTTON_TOP_EXCEPTION_DIMENS[1],
                                    right:
                                        Dimens.BUTTON_TOP_EXCEPTION_DIMENS[2]),
                                child: Container(
                                  height: 55,
                                  width: 55,
                                  // Add Contact Button
                                  child: !_displayName.startsWith("@")
                                      ? FlatButton(
                                          onPressed: () {
                                            Navigator.of(context).pop();
                                            AddContactSheet(address: _address)
                                                .mainBottomSheet(context);
                                          },
                                          splashColor: Colors.transparent,
                                          highlightColor: Colors.transparent,
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(100.0)),
                                          padding: EdgeInsets.symmetric(
                                              vertical: 10.0, horizontal: 10),
                                          child: Icon(KaliumIcons.addcontact,
                                              size: 35,
                                              color: _addressCopied
                                                  ? KaliumColors.successDark
                                                  : KaliumColors
                                                      .backgroundDark),
                                        )
                                      : SizedBox(),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      // A row for View Details button
                      Row(
                        children: <Widget>[
                          KaliumButton.buildKaliumButton(
                              KaliumButtonType.PRIMARY_OUTLINE,
                              'View Details',
                              Dimens.BUTTON_BOTTOM_DIMENS, onPressed: () {
                            Navigator.of(context).push(MaterialPageRoute(
                                builder: (BuildContext context) {
                              return UIUtil.showBlockExplorerWebview(_hash);
                            }));
                          }),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            );
          });
        });
  }
}

// monKey Overlay
class MonkeyOverlay extends ModalRoute<void> {
  var monKey;
  MonkeyOverlay(this.monKey);
  @override
  Duration get transitionDuration => Duration(milliseconds: 150);

  @override
  bool get opaque => false;

  @override
  bool get barrierDismissible => false;

  @override
  Color get barrierColor => KaliumColors.overlay70;

  @override
  String get barrierLabel => null;

  @override
  bool get maintainState => false;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: _buildOverlayContent(context),
      ),
    );
  }

  Widget _buildOverlayContent(BuildContext context) {
    return Container(
      constraints: BoxConstraints.expand(),
      child: Stack(
        children: <Widget>[
          GestureDetector(
            onTap: () {
              Navigator.pop(context);
            },
            child: Container(
              color: Colors.transparent,
              child: SizedBox.expand(),
              constraints: BoxConstraints.expand(),
            ),
          ),
          Center(
            child: ClipOval(
              child: AnimatedContainer(
                curve: Curves.elasticInOut,
                duration: Duration(milliseconds: 200),
                decoration: BoxDecoration(),
                width: MediaQuery.of(context).size.width,
                height: MediaQuery.of(context).size.width,
                child: monKey,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: animation,
        child: child,
      ),
    );
  }
}
