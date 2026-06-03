import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart'
    if (dart.library.io) 'att_stub.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MopApp());
}

class MopApp extends StatelessWidget {
  const MopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Moppen.app',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF8F9FA),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1)),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2D3142),
            height: 1.4,
          ),
          bodySmall: TextStyle(fontSize: 12, color: Colors.grey),
          labelLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF2D3142),
          elevation: 0.5,
          centerTitle: true,
          iconTheme: IconThemeData(color: Color(0xFF6366F1)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6366F1),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
          ),
        ),
      ),
      home: const MopScherm(),
    );
  }
}

class MopScherm extends StatefulWidget {
  const MopScherm({super.key});

  @override
  State<MopScherm> createState() => _MopSchermState();
}

class _MopSchermState extends State<MopScherm> {
  static const int _gratisLimiet = 100;
  static const int _promoInterval = 10;
  static const int _adInterval = 7;
  static const String _productId = 'verwijderads';

  JokeManager? _jokeManager;
  Map<String, dynamic>? huidigItem;
  bool antwoordZichtbaar = false;
  bool isAanHetLaden = true;
  String? foutMelding;

  BannerAd? _bannerAd;
  bool _isBannerLoaded = false;
  InterstitialAd? _interstitialAd;
  int _sessionClicks = 0;
  bool _isAdsRemoved = false;
  int _interstitialRetryAttempts = 0;
  bool _hasSeenFirstCycleDialog = false;

  final InAppPurchase _iap = InAppPurchase.instance;
  late StreamSubscription<List<PurchaseDetails>> _subscription;

  @override
  void initState() {
    super.initState();
    _initApp();
    _subscription = _iap.purchaseStream.listen(
      (purchases) => _handlePurchaseUpdates(purchases),
      onDone: () => _subscription.cancel(),
      onError: (error) => debugPrint("Aankoop fout: $error"),
    );
  }

  Future<void> _initApp() async {
    setState(() {
      isAanHetLaden = true;
      foutMelding = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      _isAdsRemoved = prefs.getBool('ads_removed') ?? false;
      if (Platform.isIOS || Platform.isMacOS) {
        await AppTrackingTransparency.requestTrackingAuthorization();
      }
      _hasSeenFirstCycleDialog = prefs.getBool('has_seen_first_cycle') ?? false;

      if (await _iap.isAvailable()) {
        await _iap.restorePurchases();
      }

      if (!_isAdsRemoved) {
        await MobileAds.instance.initialize();
        _loadBanner();
        _loadInterstitial();
      }

      final manager = JokeManager();
      await manager.init(isProUser: _isAdsRemoved);

      if (mounted) {
        setState(() {
          _jokeManager = manager;
          if (manager.currentIndex == 0) {
            huidigItem = _jokeManager!.getNextJoke();
          } else {
            huidigItem = _jokeManager!.getCurrentJoke();
          }
          isAanHetLaden = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isAanHetLaden = false;
          foutMelding =
              "Kon de moppen niet laden. Controleer je internetverbinding.";
        });
      }
    }
  }

  // --- ADVERTENTIES ---
  void _loadBanner() {
    if (_isAdsRemoved) return;
    _bannerAd = BannerAd(
      adUnitId: Platform.isIOS
          ? 'ca-app-pub-3858244343033398/7789319358'
          : 'ca-app-pub-3858244343033398/2738014713',
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _isBannerLoaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          Future.delayed(const Duration(seconds: 30), () => _loadBanner());
        },
      ),
    )..load();
  }

  void _loadInterstitial() {
    if (_isAdsRemoved) return;
    InterstitialAd.load(
      adUnitId: Platform.isIOS
          ? 'ca-app-pub-3858244343033398/6281063465'
          : 'ca-app-pub-3858244343033398/9933483615',
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interstitialAd = ad;
          _interstitialRetryAttempts = 0;
          _interstitialAd!.fullScreenContentCallback =
              FullScreenContentCallback(
                onAdDismissedFullScreenContent: (ad) {
                  ad.dispose();
                  _loadInterstitial();
                },
              );
        },
        onAdFailedToLoad: (error) {
          _interstitialAd = null;
          _interstitialRetryAttempts++;
          int delay = pow(2, _interstitialRetryAttempts).toInt();
          if (delay <= 64) {
            Future.delayed(Duration(seconds: delay), () => _loadInterstitial());
          }
        },
      ),
    );
  }

  // --- PURCHASES ---
  void _handlePurchaseUpdates(List<PurchaseDetails> purchases) {
    for (var purchase in purchases) {
      if (purchase.status == PurchaseStatus.purchased ||
          purchase.status == PurchaseStatus.restored) {
        _applyAdsRemoval();
        if (purchase.pendingCompletePurchase) _iap.completePurchase(purchase);
      }
    }
  }

  Future<void> _applyAdsRemoval() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ads_removed', true);
    if (mounted) {
      setState(() {
        _isAdsRemoved = true;
        _bannerAd?.dispose();
        _bannerAd = null;
        _isBannerLoaded = false;
        _jokeManager?.refreshForProUpgrade();
        huidigItem = _jokeManager?.getNextJoke();
      });
    }
  }

  Future<void> _buyRemoveAds() async {
    final bool isAvailable = await _iap.isAvailable();
    if (!isAvailable) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Aankopen niet beschikbaar op dit apparaat."),
          ),
        );
      return;
    }
    final response = await _iap.queryProductDetails({_productId});
    if (response.productDetails.isNotEmpty) {
      _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(
          productDetails: response.productDetails.first,
        ),
      );
    } else {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Product niet gevonden. Probeer later opnieuw."),
          ),
        );
    }
  }

  Future<void> _restorePurchases() async {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Aankopen worden hersteld...")),
      );
    await _iap.restorePurchases();
  }

  // --- LOGICA ---
  void volgendeItem() async {
    if (_jokeManager == null) return;

    setState(() {
      _sessionClicks++;
      antwoordZichtbaar = false;
      huidigItem = _jokeManager!.getNextJoke();
    });

    if (!_isAdsRemoved) {
      if (_jokeManager!.currentIndex == _gratisLimiet &&
          !_hasSeenFirstCycleDialog) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('has_seen_first_cycle', true);
        setState(() => _hasSeenFirstCycleDialog = true);
        _showEndReachedDialog();
      } else if (_sessionClicks % _promoInterval == 0) {
        _showPromoDialog();
      } else if (_sessionClicks % _adInterval == 0 && _interstitialAd != null) {
        _interstitialAd!.show();
      }
    }
  }

  void _showEndReachedDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Wow, al 100 moppen! 🎉"),
        content: const Text(
          "Je hebt alle gratis moppen gezien en keert nu terug naar het begin. Wil je doorgaan met 2600+ extra moppen zonder reclame? Slechts €2,99.",
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _restorePurchases();
            },
            child: const Text("Herstel aankopen"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text("Nee, blijf gratis"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _buyRemoveAds();
            },
            child: const Text("Ja, upgrade nu!"),
          ),
        ],
      ),
    );
  }

  void _showPromoDialog() {
    String title;
    String content;

    if (_sessionClicks <= 30) {
      title = "Lachen is gezond! 😂";
      content =
          "Meer lachen, minder reclame? Ontgrendel 2600+ extra moppen voor €2,99.";
    } else if (_sessionClicks <= 60) {
      title = "Nog steeds aan het lachen? 🤣";
      content =
          "Upgrade naar Pro en krijg 26× meer moppen zonder reclame. Slechts €2,99!";
    } else {
      title = "Je bent een echte grappen-fan! 🌟";
      content =
          "Klaar voor 2600+ extra moppen? Geen reclame meer, slechts €2,99.";
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _restorePurchases();
            },
            child: const Text("Herstel aankopen"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Later"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _buyRemoveAds();
            },
            child: const Text("Ja, graag!"),
          ),
        ],
      ),
    );
  }

  // --- VERBETERDE RAPPORTAGE FUNCTIE ---
  Future<void> _meldMop() async {
    if (huidigItem == null) return;
    String inhoud = huidigItem!['type'] == 'mop'
        ? huidigItem!['tekst']
        : "Vraag: ${huidigItem!['vraag']}\nAntwoord: ${huidigItem!['antwoord']}";

    final String subject = Uri.encodeComponent(
      'Mop rapporteren in de Moppen.app',
    );
    final String body = Uri.encodeComponent(
      'Ik wil deze mop melden: $inhoud\n\nReden: ',
    );

    final Uri emailUri = Uri.parse(
      'mailto:rapporteer@moppen.app?subject=$subject&body=$body',
    );

    if (await canLaunchUrl(emailUri)) {
      await launchUrl(emailUri);
    }
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    _interstitialAd?.dispose();
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (foutMelding != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(foutMelding!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _initApp,
                child: const Text("Opnieuw proberen"),
              ),
            ],
          ),
        ),
      );
    }

    if (isAanHetLaden) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final int huidigeIndex = _jokeManager?.currentIndex ?? 0;
    final int totaalDatabase = _jokeManager?.totalCount ?? 0;

    final int totaalTonen = _isAdsRemoved ? totaalDatabase : _gratisLimiet;
    final int toonIndex = _isAdsRemoved
        ? huidigeIndex
        : ((huidigeIndex - 1) % _gratisLimiet) + 1;

    bool isFavoriet = _jokeManager!.isFavoriet(huidigItem?['originalIndex']);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(_isAdsRemoved ? Icons.stars : Icons.workspace_premium),
          onPressed: _isAdsRemoved ? null : () => _buyRemoveAds(),
        ),
        title: Column(
          children: [
            Text(
              _isAdsRemoved ? "Moppen Pro" : "Moppen.app",
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(
              "Mop $toonIndex van $totaalTonen",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              isFavoriet ? Icons.favorite : Icons.favorite_border,
              color: isFavoriet ? Colors.red : null,
            ),
            onPressed: () => setState(
              () => _jokeManager!.toggleFavoriet(huidigItem!['originalIndex']),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.collections_bookmark_outlined),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      FavorietenScherm(manager: _jokeManager!),
                ),
              ).then((_) => setState(() {}));
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'meld') _meldMop();
              if (v == 'restore') _restorePurchases();
            },
            itemBuilder: (c) => [
              const PopupMenuItem(value: 'meld', child: Text("Meld deze mop")),
              if (!_isAdsRemoved)
                const PopupMenuItem(
                  value: 'restore',
                  child: Text("Herstel aankopen"),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: _buildJokeContent(),
              ),
            ),
          ),
          _buildBottomSection(),
        ],
      ),
    );
  }

  Widget _buildJokeContent() {
    if (huidigItem == null) return const Text("Geen data.");
    final TextStyle tekstStijl = Theme.of(context).textTheme.headlineMedium!;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (huidigItem!['type'] == 'mop')
            Text(
              huidigItem!['tekst'],
              textAlign: TextAlign.center,
              style: tekstStijl,
            )
          else ...[
            Text(
              huidigItem!['vraag'],
              textAlign: TextAlign.center,
              style: tekstStijl,
            ),
            const SizedBox(height: 30),
            if (antwoordZichtbaar)
              Text(
                huidigItem!['antwoord'],
                textAlign: TextAlign.center,
                style: tekstStijl.copyWith(color: Colors.green),
              )
            else
              ElevatedButton(
                onPressed: () => setState(() => antwoordZichtbaar = true),
                child: const Text("Toon antwoord"),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomSection() {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: volgendeItem,
                  child: const Text("Volgende mop"),
                ),
                const SizedBox(width: 15),
                IconButton(
                  icon: const Icon(
                    Icons.share,
                    color: Color(0xFF6366F1),
                    size: 28,
                  ),
                  onPressed: () async {
                    String tekst = huidigItem!['type'] == 'mop'
                        ? huidigItem!['tekst']
                        : "${huidigItem!['vraag']}\n\n${huidigItem!['antwoord']}";
                    Share.share("$tekst\n\nLachen? Check de moppen.app 😂");
                  },
                ),
              ],
            ),
          ),
          if (!_isAdsRemoved && _isBannerLoaded && _bannerAd != null)
            SizedBox(
              width: _bannerAd!.size.width.toDouble(),
              height: _bannerAd!.size.height.toDouble(),
              child: AdWidget(ad: _bannerAd!),
            )
          else
            const SizedBox(height: 50),
        ],
      ),
    );
  }
}

// --- FAVORIETEN SCHERM ---
class FavorietenScherm extends StatefulWidget {
  final JokeManager manager;
  const FavorietenScherm({super.key, required this.manager});

  @override
  State<FavorietenScherm> createState() => _FavorietenSchermState();
}

class _FavorietenSchermState extends State<FavorietenScherm> {
  @override
  Widget build(BuildContext context) {
    final favos = widget.manager.getFavorietenContent();
    return Scaffold(
      appBar: AppBar(title: const Text("Mijn Favorieten")),
      body: favos.isEmpty
          ? const Center(child: Text("Nog geen favorieten opgeslagen."))
          : ListView.builder(
              itemCount: favos.length,
              itemBuilder: (context, index) {
                final item = favos[index];
                return Card(
                  color: Colors.white,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: ListTile(
                    title: Text(
                      item['type'] == 'mop' ? item['tekst'] : item['vraag'],
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.redAccent,
                      ),
                      onPressed: () => setState(
                        () => widget.manager.toggleFavoriet(
                          item['originalIndex'],
                        ),
                      ),
                    ),
                    onTap: () => _showFavoDetail(item),
                  ),
                );
              },
            ),
    );
  }

  void _showFavoDetail(Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        content: SingleChildScrollView(
          child: Text(
            item['type'] == 'mop'
                ? item['tekst']
                : "${item['vraag']}\n\nAntwoord: ${item['antwoord']}",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Sluit"),
          ),
        ],
      ),
    );
  }
}

// --- JOKE MANAGER ---
class JokeManager {
  List<dynamic> _allJokes = [];
  List<int> _shuffledIndices = [];
  List<int> _favorieten = [];
  int _currentIndex = 0;

  int get currentIndex => _currentIndex;
  int get totalCount => _allJokes.length;

  Future<void> init({bool isProUser = false}) async {
    final String response = await rootBundle.loadString('assets/jokes.json');
    _allJokes = json.decode(response);
    final prefs = await SharedPreferences.getInstance();

    final List<String>? favoStrings = prefs.getStringList('favorieten');
    if (favoStrings != null) {
      _favorieten = favoStrings
          .map(int.parse)
          .where((idx) => idx >= 0 && idx < _allJokes.length)
          .toList();

      if (_favorieten.length != favoStrings.length) {
        await prefs.setStringList(
          'favorieten',
          _favorieten.map((e) => e.toString()).toList(),
        );
      }
    }

    List<String>? savedOrder = prefs.getStringList('joke_order');
    _currentIndex = prefs.getInt('joke_index') ?? 0;

    const int currentDataVersion = 2;
    int savedDataVersion = prefs.getInt('data_version') ?? 1;

    bool dataVersionChanged = savedDataVersion < currentDataVersion;
    if (dataVersionChanged) {
      await prefs.setInt('data_version', currentDataVersion);
    }

    int expectedLength = isProUser ? _allJokes.length : 100;
    bool needsReset = false;

    if (savedOrder != null && savedOrder.length != expectedLength) {
      needsReset = true;
    }

    if (savedOrder == null || needsReset || dataVersionChanged) {
      _generateNewOrder(isProUser: isProUser);
    } else {
      _shuffledIndices = savedOrder.map(int.parse).toList();

      if (_currentIndex >= _shuffledIndices.length) {
        _currentIndex = 0;
        _saveToPrefs();
      }
    }
  }

  void _generateNewOrder({bool isProUser = false}) {
    if (isProUser) {
      _shuffledIndices = List.generate(_allJokes.length, (index) => index)
        ..shuffle();
    } else {
      _shuffledIndices = List.generate(100, (index) => index)..shuffle();
    }
    _currentIndex = 0;
    _saveToPrefs();
  }

  void refreshForProUpgrade() {
    _generateNewOrder(isProUser: true);
  }

  void resetToStart() {
    _currentIndex = 0;
    _saveToPrefs();
  }

  void toggleFavoriet(int? idx) {
    if (idx == null) return;
    _favorieten.contains(idx) ? _favorieten.remove(idx) : _favorieten.add(idx);
    _saveToPrefs();
  }

  bool isFavoriet(int? idx) => _favorieten.contains(idx);

  List<Map<String, dynamic>> getFavorietenContent() {
    return _favorieten.where((idx) => idx >= 0 && idx < _allJokes.length).map((
      idx,
    ) {
      var joke = Map<String, dynamic>.from(_allJokes[idx]);
      joke['originalIndex'] = idx;
      return joke;
    }).toList();
  }

  Map<String, dynamic> getNextJoke() {
    if (_shuffledIndices.isEmpty) return {"type": "mop", "tekst": "Fout"};

    if (_currentIndex >= _shuffledIndices.length) {
      bool shouldShuffleAll = _shuffledIndices.length > 100;
      _generateNewOrder(isProUser: shouldShuffleAll);
    }

    int originalIdx = _shuffledIndices[_currentIndex++];
    _saveToPrefs();
    var joke = Map<String, dynamic>.from(_allJokes[originalIdx]);
    joke['originalIndex'] = originalIdx;
    return joke;
  }

  Map<String, dynamic> getCurrentJoke() {
    if (_shuffledIndices.isEmpty) return {"type": "mop", "tekst": "Fout"};

    int indexToShow = _currentIndex > 0 ? _currentIndex - 1 : 0;

    if (indexToShow >= _shuffledIndices.length) {
      bool shouldShuffleAll = _shuffledIndices.length > 100;
      _generateNewOrder(isProUser: shouldShuffleAll);
      indexToShow = 0;
    }

    int originalIdx = _shuffledIndices[indexToShow];
    var joke = Map<String, dynamic>.from(_allJokes[originalIdx]);
    joke['originalIndex'] = originalIdx;
    return joke;
  }

  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'joke_order',
      _shuffledIndices.map((e) => e.toString()).toList(),
    );
    await prefs.setInt('joke_index', _currentIndex);
    await prefs.setStringList(
      'favorieten',
      _favorieten.map((e) => e.toString()).toList(),
    );
  }
}
