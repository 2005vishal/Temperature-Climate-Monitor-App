import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial_ble/flutter_bluetooth_serial_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF050510),
      ),
      home: const BluetoothMonitorPage(),
    );
  }
}

class BluetoothMonitorPage extends StatefulWidget {
  const BluetoothMonitorPage({Key? key}) : super(key: key);

  @override
  _BluetoothMonitorPageState createState() => _BluetoothMonitorPageState();
}

class _BluetoothMonitorPageState extends State<BluetoothMonitorPage> {
  BluetoothConnection? connection;
  bool isConnected = false;
  String sensorStatus = "System Booting...";

  double tempVal = 0.0;
  double humVal = 0.0;
  double heatIndexVal = 0.0;
  double dewPointVal = 0.0;
  double dewScale10 = 0.0;
  double coGasVal = 0.0;
  int batteryVal = 100;

  // CRITICAL SAFETY LIMITS
  final double maxTempLimit = 40.0;
  final double maxHumLimit = 75.0;
  final double maxGasLimit = 100.0;
  bool isAlertActive = false;
  String alertMessage = "";

  String _dataBuffer = "";
  // Bluetooth device MAC Address
  final String hc05MacAddress = "17:3C:9A:1D:14:0E";

  // Graph 1: Live Climate Telemetry (Temp/Hum)
  List<FlSpot> tempPoints = [];
  List<FlSpot> humPoints = [];
  int liveTimeCounter = 0;
  DateTime lastLiveGraphUpdateTime = DateTime.now();

  // Graph 2: Dedicated Live Gas Telemetry Array
  List<FlSpot> liveGasPoints = [];
  int liveGasCounter = 0;

  // Database 2: Upgraded 12-Hour Historical Micro-Storage Matrix (Max 144 Points)
  List<Map<String, dynamic>> historicalRecords = [];
  Timer? _historyLogTimer;

  // Watchdog Timers
  Timer? _heartbeatTimer;
  DateTime lastDataReceivedTime = DateTime.now();
  bool _isAttemptingConnection = false;

  // Sync Flag to separate background buffer dump
  bool isBackupStreaming = false;

  @override
  void initState() {
    super.initState();
    _loadHistoricalData();
    _requestPermissionsAndConnect();
    _startHardwareWatchdog();
    _startHistoryDataLogger();
  }

  // PHONE MEMORY STORAGE SYNC ENGINES
  Future<void> _loadHistoricalData() async {
    final prefs = await SharedPreferences.getInstance();
    final String? cachedJson = prefs.getString('climate_absolute_records_v12');
    if (cachedJson != null) {
      try {
        final List<dynamic> decodedList = json.decode(cachedJson);
        setState(() {
          historicalRecords = decodedList
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        });
      } catch (e) {
        _prefillSafeInitialTimeline();
      }
    } else {
      _prefillSafeInitialTimeline();
    }
  }

  Future<void> _saveHistoricalData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'climate_absolute_records_v12',
      json.encode(historicalRecords),
    );
  }

  void _prefillSafeInitialTimeline() {
    DateTime now = DateTime.now();
    for (int i = 143; i >= 0; i--) {
      DateTime pastTime = now.subtract(Duration(minutes: i * 5));
      String label =
          "${pastTime.hour.toString().padLeft(2, '0')}:${pastTime.minute.toString().padLeft(2, '0')}";
      historicalRecords.add({
        'time': label,
        'temp': 28.0 + sin(i * 0.1),
        'hum': 52.0 + cos(i * 0.1),
        'heat': 30.0,
        'dew': 20.0,
        'gas': 25.0,
      });
    }
  }

  void _requestPermissionsAndConnect() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.location,
    ].request();

    if (statuses[Permission.bluetoothConnect] == PermissionStatus.granted &&
        statuses[Permission.bluetoothScan] == PermissionStatus.granted) {
      _isAttemptingConnection = false;
      _connectToHC05Classic();
    } else {
      setState(() {
        sensorStatus = "Permission Denied";
      });
    }
  }

  // FIXED: Watchdog interval set to check every 2s, triggers reset if no data for 4s
  void _startHardwareWatchdog() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (isConnected) {
        final secondsSinceLastData = DateTime.now()
            .difference(lastDataReceivedTime)
            .inSeconds;
        if (secondsSinceLastData >= 4) {
          print(
            "[WATCHDOG] Silent for 4s, restarting link channel immediately...",
          );
          _handleHardwareDisconnect();
        }
      } else {
        if (!_isAttemptingConnection) {
          _connectToHC05Classic();
        }
      }
    });
  }

  void _startHistoryDataLogger() {
    _historyLogTimer?.cancel();
    _historyLogTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      if (isConnected && tempVal > 1.0 && humVal > 1.0 && !isBackupStreaming) {
        _insertCurrentReadingIntoTimeline();
      }
    });
  }

  void _insertCurrentReadingIntoTimeline() {
    setState(() {
      DateTime now = DateTime.now();
      String currentLabel =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";

      if (historicalRecords.length >= 144) {
        historicalRecords.removeAt(0);
      }

      historicalRecords.add({
        'time': currentLabel,
        'temp': double.parse(tempVal.toStringAsFixed(1)),
        'hum': double.parse(humVal.toStringAsFixed(1)),
        'heat': double.parse(heatIndexVal.toStringAsFixed(1)),
        'dew': double.parse(dewPointVal.toStringAsFixed(1)),
        'gas': double.parse(coGasVal.toStringAsFixed(1)),
      });
      _saveHistoricalData();
    });
  }

  void _triggerArduinoBackupRequest() async {
    if (connection != null && connection!.isConnected) {
      print("Sending Backup Handshake Request 'b' to Arduino...");
      connection!.output.add(utf8.encode('b'));
      await connection!.output.allSent;
    }
  }

  void _handleHardwareDisconnect() {
    if (!mounted) return;
    _dataBuffer = "";
    try {
      if (connection != null) {
        connection?.close();
        connection?.dispose();
      }
    } catch (e) {
      print("Error releasing native socket: $e");
    }
    setState(() {
      connection = null;
      isConnected = false;
      isBackupStreaming = false;
      sensorStatus = "Searching...";
      tempVal = 0.0;
      humVal = 0.0;
      heatIndexVal = 0.0;
      dewPointVal = 0.0;
      dewScale10 = 0.0;
      coGasVal = 0.0;
      isAlertActive = false;
    });
  }

  void _connectToHC05Classic() async {
    if (_isAttemptingConnection) return;
    _isAttemptingConnection = true;
    setState(() => sensorStatus = "Searching...");

    if (connection != null) {
      try {
        connection?.close();
        connection?.dispose();
        connection = null;
      } catch (e) {}
    }

    await Future.delayed(const Duration(milliseconds: 600));

    try {
      List<BluetoothDevice> bondedDevices = await FlutterBluetoothSerial
          .instance
          .getBondedDevices();
      BluetoothDevice? myDevice;

      for (var device in bondedDevices) {
        if (device.address.trim().toUpperCase() ==
            hc05MacAddress.trim().toUpperCase()) {
          myDevice = device;
          break;
        }
      }

      if (myDevice != null) {
        print("[BLUETOOTH] Opening standard verified RFCOMM pipeline...");

        BluetoothConnection.toAddress(myDevice.address)
            .then((_connection) {
              setState(() {
                connection = _connection;
                isConnected = true;
                _isAttemptingConnection = false;
                sensorStatus = "Connected Live";
                lastDataReceivedTime = DateTime.now();
              });

              _triggerArduinoBackupRequest();

              connection!.input!
                  .listen(_onDataReceived)
                  .onDone(() => _handleHardwareDisconnect());
            })
            .catchError((error) {
              _isAttemptingConnection = false;
              setState(() => sensorStatus = "Scanning Range...");
            });
      } else {
        _isAttemptingConnection = false;
        setState(() => sensorStatus = "Not Paired in Settings");
      }
    } catch (e) {
      _isAttemptingConnection = false;
      setState(() => sensorStatus = "Scanning Range...");
    }
  }

  void calculateMetrics(double t, double h, double gas, int bat) {
    if (t <= 0.0 || h <= 0.0) return;

    double alpha = ((17.27 * t) / (237.7 + t)) + log(h / 100.0);
    double dp = (237.7 * alpha) / (17.27 - alpha);
    double calculatedScale = ((dp - (-5)) / (35 - (-5))) * 10;
    double scale10 = calculatedScale.clamp(0.0, 10.0);

    double T_f = (t * 1.8) + 32.0;
    double hiFahrenheit = T_f;
    if (T_f >= 80.0) {
      hiFahrenheit =
          -42.379 +
          2.04901523 * T_f +
          10.14333127 * h -
          0.22475541 * T_f * h -
          0.00683783 * T_f * T_f -
          0.05481717 * h * h +
          0.00122874 * T_f * T_f * h +
          0.00085282 * T_f * h * h -
          0.00000199 * T_f * T_f * h * h;
    }
    double hiCelsius = (hiFahrenheit - 32.0) / 1.8;

    bool triggerAlert = false;
    String currentAlertMsg = "";

    if (bat < 30) {
      triggerAlert = true;
      currentAlertMsg = "⚠️ CRITICAL: LOW MODULE BATTERY VOLTAGE!";
    } else if (gas > maxGasLimit) {
      triggerAlert = true;
      currentAlertMsg = "🚨 TOXIC CARBON MONOXIDE DETECTED!";
    } else if (t > maxTempLimit && h > maxHumLimit) {
      triggerAlert = true;
      currentAlertMsg = "🚨 HIGH TEMP & HUMIDITY!";
    } else if (t > maxTempLimit) {
      triggerAlert = true;
      currentAlertMsg = "⚠️ TEMPERATURE LIMIT EXCEEDED!";
    } else if (h > maxHumLimit) {
      triggerAlert = true;
      currentAlertMsg = "⚠️ HUMIDITY LIMIT EXCEEDED!";
    }

    setState(() {
      tempVal = t;
      humVal = h;
      coGasVal = gas;
      batteryVal = bat;
      dewPointVal = dp;
      dewScale10 = scale10;
      heatIndexVal = hiCelsius;
      isAlertActive = triggerAlert;
      alertMessage = currentAlertMsg;

      if (DateTime.now().difference(lastLiveGraphUpdateTime).inMilliseconds >=
          1500) {
        liveTimeCounter++;
        liveGasCounter++;

        tempPoints.add(
          FlSpot(
            liveTimeCounter.toDouble(),
            double.parse(tempVal.toStringAsFixed(1)),
          ),
        );
        humPoints.add(
          FlSpot(
            liveTimeCounter.toDouble(),
            double.parse(humVal.toStringAsFixed(1)),
          ),
        );
        liveGasPoints.add(
          FlSpot(
            liveGasCounter.toDouble(),
            double.parse(coGasVal.toStringAsFixed(1)),
          ),
        );

        if (tempPoints.length > 15) {
          tempPoints.removeAt(0);
          humPoints.removeAt(0);
        }
        if (liveGasPoints.length > 15) {
          liveGasPoints.removeAt(0);
        }
        lastLiveGraphUpdateTime = DateTime.now();
      }
    });
  }

  void _onDataReceived(Uint8List rawData) {
    if (rawData.isEmpty) return;
    lastDataReceivedTime = DateTime.now();

    String chunk = latin1.decode(rawData);
    _dataBuffer += chunk;

    while (_dataBuffer.contains('\n')) {
      int lineBreakIndex = _dataBuffer.indexOf('\n');
      String completeLine = _dataBuffer.substring(0, lineBreakIndex).trim();
      _dataBuffer = _dataBuffer.substring(lineBreakIndex + 1);

      if (completeLine.isEmpty) continue;

      if (completeLine.contains("BACKUP_START")) {
        isBackupStreaming = true;
        historicalRecords.clear();
        continue;
      }

      if (completeLine.contains("BACKUP_END")) {
        isBackupStreaming = false;
        _saveHistoricalData();
        setState(() {});
        continue;
      }

      if (isBackupStreaming && completeLine.startsWith("B_DATA")) {
        try {
          final RegExp tempRegex = RegExp(r'T:\s*([0-9.]+)');
          final RegExp humRegex = RegExp(r'H:\s*([0-9.]+)');
          final RegExp gasRegex = RegExp(r'C:\s*([0-9.]+)');

          final Match? tempMatch = tempRegex.firstMatch(completeLine);
          final Match? humMatch = humRegex.firstMatch(completeLine);
          final Match? gasMatch = gasRegex.firstMatch(completeLine);

          if (tempMatch != null && humMatch != null && gasMatch != null) {
            double parsedT = double.parse(tempMatch.group(1)!);
            double parsedH = double.parse(humMatch.group(1)!);
            double parsedGas = double.parse(gasMatch.group(1)!);

            int currentPoints = historicalRecords.length;
            DateTime timeSlot = DateTime.now().subtract(
              Duration(minutes: (143 - currentPoints) * 5),
            );
            String slotLabel =
                "${timeSlot.hour.toString().padLeft(2, '0')}:${timeSlot.minute.toString().padLeft(2, '0')}";

            double alpha =
                ((17.27 * parsedT) / (237.7 + parsedT)) + log(parsedH / 100.0);
            double dp = (237.7 * alpha) / (17.27 - alpha);

            historicalRecords.add({
              'time': slotLabel,
              'temp': parsedT,
              'hum': parsedH,
              'heat': parsedT + 1.2,
              'dew': double.parse(dp.toStringAsFixed(1)),
              'gas': parsedGas,
            });
          }
        } catch (e) {}
        continue;
      }

      if (!isBackupStreaming) {
        try {
          final RegExp liveTempRegex = RegExp(r'Temp:\s*([0-9.]+)');
          final RegExp liveHumRegex = RegExp(r'Humidity:\s*([0-9.]+)');
          // FIXED REGEX: Extracts numbers perfectly even if followed by PPM text string
          final RegExp liveGasRegex = RegExp(r'CO:\s*([0-9.]+)');
          final RegExp liveBatRegex = RegExp(r'Bat:\s*([0-9]+)%');

          final Match? tMatch = liveTempRegex.firstMatch(completeLine);
          final Match? hMatch = liveHumRegex.firstMatch(completeLine);
          final Match? gMatch = liveGasRegex.firstMatch(completeLine);
          final Match? bMatch = liveBatRegex.firstMatch(completeLine);

          if (tMatch != null && hMatch != null) {
            double parsedT = double.parse(tMatch.group(1)!);
            double parsedH = double.parse(hMatch.group(1)!);

            double parsedGas = 0.0;
            if (gMatch != null) {
              parsedGas = double.tryParse(gMatch.group(1)!) ?? 0.0;
            }

            int parsedBat = 100;
            if (bMatch != null) {
              parsedBat = int.parse(bMatch.group(1)!);
            }

            if (parsedT > 0.1 && parsedH > 0.1) {
              calculateMetrics(parsedT, parsedH, parsedGas, parsedBat);
            }
          }
        } catch (e) {}
      }
    }

    if (_dataBuffer.length > 25000 && !isBackupStreaming) {
      _dataBuffer = "";
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          _buildBackgroundDecorations(),
          SafeArea(
            child: PageView(
              physics: const BouncingScrollPhysics(),
              children: [
                _buildMainDashboard(),
                _buildAnalysisFrame(),
                _buildHistory12HFrame(),
                _buildMQ7GasMonitorFrame(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackgroundDecorations() {
    return Stack(
      children: [
        Positioned(
          top: -120,
          right: -60,
          child: _blob(
            280,
            isAlertActive
                ? Colors.red.withOpacity(0.12)
                : Colors.blue.withOpacity(0.12),
          ),
        ),
        Positioned(
          bottom: -80,
          left: -60,
          child: _blob(240, Colors.orange.withOpacity(0.08)),
        ),
      ],
    );
  }

  Widget _buildMainDashboard() {
    bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    String gasSafetyText = coGasVal > maxGasLimit
        ? "TOXIC HAZARD"
        : (coGasVal > 35 ? "POOR AIR" : "SAFE / GOOD");
    Color gasCardColor = coGasVal > maxGasLimit
        ? Colors.redAccent
        : (coGasVal > 35 ? Colors.yellow : Colors.greenAccent);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: [
          _buildHeader(),
          if (isAlertActive) ...[
            const SizedBox(height: 10),
            _buildAlertStatusBanner(),
          ],
          const SizedBox(height: 15),
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: isLandscape
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              _buildBatteryVisualCard(),
                              const SizedBox(height: 14),
                              _glassCard(
                                "ROOM TEMP",
                                "${tempVal.toStringAsFixed(1)} °C",
                                Icons.thermostat_rounded,
                                Colors.orange,
                              ),
                              const SizedBox(height: 14),
                              _glassCard(
                                "FEELS LIKE",
                                "${heatIndexVal.toStringAsFixed(1)} °C",
                                Icons.wb_sunny_rounded,
                                Colors.redAccent,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            children: [
                              _glassCard(
                                "MQ7 GAS LEVEL",
                                "${coGasVal.toStringAsFixed(0)} PPM",
                                Icons.cloud_queue_rounded,
                                gasCardColor,
                              ),
                              const SizedBox(height: 14),
                              _glassCard(
                                "HUMIDITY",
                                "${humVal.toStringAsFixed(1)} %",
                                Icons.water_drop_rounded,
                                Colors.blue,
                              ),
                              const SizedBox(height: 14),
                              _glassCard(
                                "DEW INDEX",
                                dewScale10.toStringAsFixed(1),
                                Icons.speed_rounded,
                                Colors.tealAccent,
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        _buildBatteryVisualCard(),
                        const SizedBox(height: 14),
                        _glassCard(
                          "ROOM TEMP",
                          "${tempVal.toStringAsFixed(1)} °C",
                          Icons.thermostat_rounded,
                          Colors.orange,
                        ),
                        const SizedBox(height: 14),
                        _glassCard(
                          "HUMIDITY",
                          "${humVal.toStringAsFixed(1)} %",
                          Icons.water_drop_rounded,
                          Colors.blue,
                        ),
                        const SizedBox(height: 14),
                        _glassCard(
                          "FEELS LIKE",
                          "${heatIndexVal.toStringAsFixed(1)} °C",
                          Icons.wb_sunny_rounded,
                          Colors.redAccent,
                        ),
                        const SizedBox(height: 14),
                        _glassMeterCard(
                          "DEW INDEX",
                          dewScale10,
                          "${dewPointVal.toStringAsFixed(1)} °C",
                          Icons.speed_rounded,
                          Colors.tealAccent,
                        ),
                        const SizedBox(height: 14),
                        _glassCard(
                          "MQ7 CO GAS LEVEL",
                          "${coGasVal.toStringAsFixed(0)} PPM ($gasSafetyText)",
                          Icons.cloud_queue_rounded,
                          gasCardColor,
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            "Design & Development by Vishal Patwa",
            style: TextStyle(
              color: Colors.white38,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            "Swipe Right for Telemetry Panels ➔",
            style: TextStyle(color: Colors.white24, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildBatteryVisualCard() {
    Color fillBackgroundColor;
    if (batteryVal > 60) {
      fillBackgroundColor = Colors.greenAccent;
    } else if (batteryVal >= 30) {
      fillBackgroundColor = Colors.orangeAccent;
    } else {
      fillBackgroundColor = Colors.redAccent;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.06),
            Colors.white.withOpacity(0.01),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "HARDWARE BATTERY MATRIX",
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    "$batteryVal",
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const Text(
                    " % Capacity",
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 55,
                height: 26,
                padding: const EdgeInsets.all(2.5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white60, width: 2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2.5),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: batteryVal / 100.0,
                    child: Container(color: fillBackgroundColor),
                  ),
                ),
              ),
              Container(
                width: 3,
                height: 10,
                decoration: const BoxDecoration(
                  color: Colors.white60,
                  borderRadius: BorderRadius.only(
                    topRight: Radius.circular(2),
                    bottomRight: Radius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                "SENSORS DASHBOARD",
                style: TextStyle(
                  letterSpacing: 1.5,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.tealAccent,
                ),
              ),
              SizedBox(height: 2),
              Text(
                "Climate Matrix",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isConnected
                ? Colors.green.withOpacity(0.08)
                : Colors.red.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isConnected
                  ? Colors.green.withOpacity(0.4)
                  : Colors.red.withOpacity(0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 3,
                backgroundColor: isConnected ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 5),
              Text(
                sensorStatus,
                style: TextStyle(
                  color: isConnected ? Colors.green : Colors.red,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAlertStatusBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red, width: 1.2),
      ),
      child: Text(
        alertMessage,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _glassCard(String title, String val, IconData icon, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.06),
            Colors.white.withOpacity(0.01),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                val,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          Icon(icon, color: color.withOpacity(0.2), size: 38),
        ],
      ),
    );
  }

  Widget _glassMeterCard(
    String title,
    double score,
    String rawTemp,
    IconData icon,
    Color color,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.06),
            Colors.white.withOpacity(0.01),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
              Icon(icon, color: color.withOpacity(0.2), size: 32),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                "${score.toStringAsFixed(1)} ",
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Text(
                "/10 Level",
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: 5,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(3),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: score / 10.0,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Value: $rawTemp",
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalysisFrame() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "REAL-TIME CLIMATE MATRIX",
            style: TextStyle(
              letterSpacing: 2,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.tealAccent,
            ),
          ),
          const Text(
            "Live Curved Telemetry",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 25),
          Expanded(
            child: tempPoints.isEmpty
                ? const Center(
                    child: Text(
                      "Awaiting live data...",
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      minY: 0,
                      maxY: 100,
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          tooltipBgColor: const Color(0xFF1D1E33),
                          getTooltipItems: (List<LineBarSpot> touchedSpots) {
                            return touchedSpots.map((spot) {
                              String label = spot.barIndex == 0
                                  ? "Temp: "
                                  : "Hum: ";
                              String unit = spot.barIndex == 0 ? " °C" : " %";
                              return LineTooltipItem(
                                "$label${spot.y.toStringAsFixed(1)}$unit",
                                const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              );
                            }).toList();
                          },
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        getDrawingHorizontalLine: (v) =>
                            FlLine(color: Colors.white10),
                        getDrawingVerticalLine: (v) =>
                            FlLine(color: Colors.white10),
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        topTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 35,
                            interval: 20,
                          ),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: Colors.white24),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: tempPoints,
                          isCurved: true,
                          color: Colors.orange,
                          barWidth: 3.2,
                          dotData: const FlDotData(show: true),
                        ),
                        LineChartBarData(
                          spots: humPoints,
                          isCurved: true,
                          color: Colors.blue,
                          barWidth: 3.2,
                          dotData: const FlDotData(show: true),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 15),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _legend(Colors.orange, "Live Temp (°C)"),
              const SizedBox(width: 25),
              _legend(Colors.blue, "Live Humidity (%)"),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildHistory12HFrame() {
    List<FlSpot> tempSpots = [];
    List<FlSpot> humSpots = [];
    List<FlSpot> heatSpots = [];
    List<FlSpot> dewSpots = [];

    for (int i = 0; i < historicalRecords.length; i++) {
      double xCoord = (i + 1).toDouble();
      var r = historicalRecords[i];
      tempSpots.add(FlSpot(xCoord, r['temp']));
      humSpots.add(FlSpot(xCoord, r['hum']));
      heatSpots.add(FlSpot(xCoord, r['heat']));
      dewSpots.add(FlSpot(xCoord, r['dew']));
    }

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "LONG-TERM HISTORICAL MATRIX",
            style: TextStyle(
              letterSpacing: 2,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.tealAccent,
            ),
          ),
          const Text(
            "12-Hour Real Clock Trends",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 25),
          Expanded(
            child: historicalRecords.isEmpty
                ? const Center(
                    child: Text(
                      "Syncing real storage timelines...",
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      minX: 1.0,
                      maxX: 144.0,
                      minY: 0,
                      maxY: 100,
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          tooltipBgColor: const Color(0xFF1D1E33),
                          getTooltipItems: (List<LineBarSpot> touchedSpots) {
                            return touchedSpots.map((spot) {
                              String name = spot.barIndex == 0
                                  ? "Temp: "
                                  : (spot.barIndex == 1
                                        ? "Hum: "
                                        : (spot.barIndex == 2
                                              ? "Feels: "
                                              : "Dew: "));

                              return LineTooltipItem(
                                "$name${spot.y.toStringAsFixed(1)}",
                                const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              );
                            }).toList();
                          },
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        getDrawingHorizontalLine: (v) =>
                            FlLine(color: Colors.white10),
                        getDrawingVerticalLine: (v) =>
                            FlLine(color: Colors.white10),
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        topTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 30,
                            interval: 20,
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            interval: 12.0,
                            getTitlesWidget: (value, meta) {
                              int idx = value.toInt() - 1;
                              if (idx >= 0 && idx < historicalRecords.length) {
                                if (idx == 0 || (idx + 1) % 12 == 0) {
                                  return SideTitleWidget(
                                    axisSide: meta.axisSide,
                                    child: Text(
                                      historicalRecords[idx]['time'] ?? "",
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 8,
                                      ),
                                    ),
                                  );
                                }
                              }
                              return const SizedBox.shrink();
                            },
                          ),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: Colors.white24),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: tempSpots,
                          isCurved: true,
                          color: Colors.orange,
                          barWidth: 2.2,
                          dotData: const FlDotData(show: false),
                        ),
                        LineChartBarData(
                          spots: humSpots,
                          isCurved: true,
                          color: Colors.blue,
                          barWidth: 2.2,
                          dotData: const FlDotData(show: false),
                        ),
                        LineChartBarData(
                          spots: heatSpots,
                          isCurved: true,
                          color: Colors.redAccent,
                          barWidth: 2.2,
                          dotData: const FlDotData(show: false),
                        ),
                        LineChartBarData(
                          spots: dewSpots,
                          isCurved: true,
                          color: Colors.tealAccent,
                          barWidth: 2.2,
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 15),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              _legend(Colors.orange, "Temp"),
              _legend(Colors.blue, "Hum"),
              _legend(Colors.redAccent, "Feels"),
              _legend(Colors.tealAccent, "Dew"),
            ],
          ),
          const SizedBox(height: 15),
        ],
      ),
    );
  }

  // FIXED OVERLAPPING: Re-engineered layout to safely stack components using SingleChildScrollView and fixed bounds
  Widget _buildMQ7GasMonitorFrame() {
    List<FlSpot> histGasSpots = [];
    for (int i = 0; i < historicalRecords.length; i++) {
      double xCoord = (i + 1).toDouble();
      histGasSpots.add(FlSpot(xCoord, historicalRecords[i]['gas']));
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "AIR QUALITY & TOXIC GAS DETECTOR",
              style: TextStyle(
                letterSpacing: 2,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.greenAccent,
              ),
            ),
            const Text(
              "MQ7 Gas Environment Station",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 20),

            // Section A: Real-Time Stream Chart
            const Text(
              "Real-Time CO Gas PPM Telemetry",
              style: TextStyle(
                fontSize: 11,
                color: Colors.white54,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height:
                  200, // Fixed height to prevent squishing and overlap bounds
              child: liveGasPoints.isEmpty
                  ? const Center(
                      child: Text(
                        "Initializing MQ7 stream matrix...",
                        style: TextStyle(color: Colors.white24, fontSize: 12),
                      ),
                    )
                  : LineChart(
                      LineChartData(
                        minY: 0,
                        maxY: 500,
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: true,
                          getDrawingHorizontalLine: (v) =>
                              FlLine(color: Colors.white10),
                          getDrawingVerticalLine: (v) =>
                              FlLine(color: Colors.white10),
                        ),
                        titlesData: FlTitlesData(
                          show: true,
                          topTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 35,
                              interval: 100,
                            ),
                          ),
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: Border.all(color: Colors.white12),
                        ),
                        lineBarsData: [
                          LineChartBarData(
                            spots: liveGasPoints,
                            isCurved: true,
                            color: Colors.greenAccent,
                            barWidth: 3.0,
                            dotData: const FlDotData(show: true),
                            belowBarData: BarAreaData(
                              show: true,
                              color: Colors.greenAccent.withOpacity(0.04),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),

            const SizedBox(height: 20),
            const Divider(height: 1, color: Colors.white12),
            const SizedBox(height: 20),

            // Section B: Historical Log Loop Chart
            const Text(
              "Historical CO Gas Trends (12H Loops)",
              style: TextStyle(
                fontSize: 11,
                color: Colors.white54,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height:
                  200, // Fixed height prevents overlap on different tablet screens
              child: historicalRecords.isEmpty
                  ? const Center(
                      child: Text(
                        "Awaiting timeline formation...",
                        style: TextStyle(color: Colors.white24, fontSize: 12),
                      ),
                    )
                  : LineChart(
                      LineChartData(
                        minX: 1.0,
                        maxX: 144.0,
                        minY: 0,
                        maxY: 500,
                        lineTouchData: LineTouchData(
                          touchTooltipData: LineTouchTooltipData(
                            tooltipBgColor: const Color(0xFF1D1E33),
                            getTooltipItems: (List<LineBarSpot> touchedSpots) {
                              return touchedSpots.map((spot) {
                                return LineTooltipItem(
                                  "CO: ${spot.y.toStringAsFixed(1)} PPM",
                                  const TextStyle(
                                    color: Colors.tealAccent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                );
                              }).toList();
                            },
                          ),
                        ),
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: true,
                          getDrawingHorizontalLine: (v) =>
                              FlLine(color: Colors.white10),
                          getDrawingVerticalLine: (v) =>
                              FlLine(color: Colors.white10),
                        ),
                        titlesData: FlTitlesData(
                          show: true,
                          topTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 35,
                              interval: 100,
                            ),
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              interval: 12.0,
                              getTitlesWidget: (value, meta) {
                                int idx = value.toInt() - 1;
                                if (idx >= 0 &&
                                    idx < historicalRecords.length) {
                                  if (idx == 0 || (idx + 1) % 12 == 0) {
                                    return SideTitleWidget(
                                      axisSide: meta.axisSide,
                                      child: Text(
                                        historicalRecords[idx]['time'] ?? "",
                                        style: const TextStyle(
                                          color: Colors.white38,
                                          fontSize: 8,
                                        ),
                                      ),
                                    );
                                  }
                                }
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                        ),
                        borderData: FlBorderData(
                          show: true,
                          border: Border.all(color: Colors.white12),
                        ),
                        lineBarsData: [
                          LineChartBarData(
                            spots: histGasSpots,
                            isCurved: true,
                            color: Colors.tealAccent,
                            barWidth: 2.5,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: Colors.tealAccent.withOpacity(0.02),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _blob(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [BoxShadow(color: color, blurRadius: 120, spreadRadius: 60)],
      ),
    );
  }

  Widget _legend(Color c, String t) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      CircleAvatar(radius: 4, backgroundColor: c),
      const SizedBox(width: 5),
      Text(t, style: const TextStyle(fontSize: 11, color: Colors.white70)),
    ],
  );
}
