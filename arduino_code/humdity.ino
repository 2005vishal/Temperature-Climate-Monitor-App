#include "DHT.h"

#define DHTPIN 9
#define DHTTYPE DHT11
DHT dht(DHTPIN, DHTTYPE);

const int mq7Pin = A0;
const int batteryPin = A1;     // 🔥 NEW: Battery monitoring pin (1k + 1k divider)
const int buzzerPin = 8;
const int mq7SwitchPin = 7;    // Pin connected to the Base of BC547 transistor

// Ultra-Low Memory Backup Arrays (RAM Protected)
const int maxBackupPoints = 144; 
int backupCO[maxBackupPoints];    
byte backupTemp[maxBackupPoints]; 
byte backupHum[maxBackupPoints];  
int totalSavedPoints = 0;

unsigned long lastLiveSendTime = 0;
unsigned long lastBackupSaveTime = 0;
unsigned long sensorActivationTime = 0; // Tracks when the MQ7 transistor was turned ON

bool isSensorReady = false; 

const unsigned long liveInterval = 2000;          
const unsigned long backupInterval = 300000;      
const unsigned long warmUpDuration = 120000;       // 2 Minutes delay for chemistry stability
const unsigned long buzzerWarmUpDuration = 600000; // 🔥 NEW: 10 Minutes (600,000 ms) safety delay for Buzzer

void setup() {
  Serial.begin(38400);
  dht.begin();
  
  pinMode(buzzerPin, OUTPUT);
  digitalWrite(buzzerPin, LOW); 
  
  pinMode(mq7SwitchPin, OUTPUT);
  digitalWrite(mq7SwitchPin, LOW); // Keep MQ7 completely OFF at startup
  
  for(int i=0; i<maxBackupPoints; i++) {
    backupCO[i] = -1; 
  }
  
  Serial.println(F("--- System Initializing (Waiting 10s for Core Stability...) ---"));
  delay(10000); // 10-second delay for core microcontroller stability
  
  // Turn ON the MQ7 via Transistor
  digitalWrite(mq7SwitchPin, HIGH);
  sensorActivationTime = millis(); // Record the exact timestamp when MQ7 received power
  
  Serial.println(F("[POWER] MQ7 Sensor Activated. Initializing Stabilization Cycles..."));
}

void loop() {
  unsigned long currentTime = millis();

  // Non-blocking check to determine if the 2-minute basic heating phase is complete
  if (!isSensorReady && (currentTime - sensorActivationTime >= warmUpDuration)) {
    isSensorReady = true;
    Serial.println(F("[STATUS] MQ7 Sensor Basic Heating Complete!"));
  }

  // 1. BACKUP DATA DUMP TO TABLET (Using Hardware Serial)
  if (Serial.available() > 0) {
    char req = Serial.read();
    if (req == 'b') { 
      Serial.print("BACKUP_START\n");
      delay(30);

      for (int i = 0; i < totalSavedPoints; i++) {
        if (backupCO[i] != -1) {
          Serial.print("B_DATA T: ");
          Serial.print(backupTemp[i]); 
          Serial.print(" H: ");
          Serial.print(backupHum[i]);
          Serial.print(" C: ");
          Serial.print(backupCO[i]);
          Serial.print("\n");
          delay(25); 
        }
      }
      Serial.print("BACKUP_END\n");
    }
  }

  // 2. LIVE TELEMETRY LOGIC (Every 2 seconds)
  if (currentTime - lastLiveSendTime >= liveInterval) {
    lastLiveSendTime = currentTime;

    float h = dht.readHumidity();
    float t = dht.readTemperature();
    
    if (isnan(h) || isnan(t)) { t = 0.0; h = 0.0; }
    
    int coPpm = 0; // Default to 0 during warm-up phase

    // Only read and process MQ7 data if the sensor has finished its basic warm-up
    if (isSensorReady) {
      int rawAnalog = analogRead(mq7Pin);

      // Strict baseline clamping to filter noise
      if (rawAnalog < 40) rawAnalog = 40;
      if (rawAnalog > 800) rawAnalog = 800;

      coPpm = map(rawAnalog, 40, 800, 0, 500);
      
      if (coPpm < 0) coPpm = 0;
      if (coPpm > 500) coPpm = 500;

      // 🔥 UPDATED: Safety Buzzer Alert (Only triggers AFTER 10 minutes of complete system runtime)
      if ((currentTime - sensorActivationTime >= buzzerWarmUpDuration) && (coPpm >= 100)) {
        digitalWrite(buzzerPin, HIGH);
      } else {
        digitalWrite(buzzerPin, LOW);
      }
    } else {
      // Ensure buzzer stays OFF during the unstable pre-heating phase
      digitalWrite(buzzerPin, LOW); 
    }
    
    // 🔥 NEW UPDATED LOGIC: Moving Average Filter (10 Readings for Stability)
    long batterySum = 0;
    for (int i = 0; i < 10; i++) {
      batterySum += analogRead(batteryPin);
      delay(5); // Chota sa gap har reading ke beech mein stability ke liye
    }
    int batteryRaw = batterySum / 10; // Averaged stable value
    
    // Baki calculation ekdam same rahega
    float batteryVoltage = (batteryRaw * 5.0 / 1023.0) * 2.0; 
    int batteryPercentage = map(batteryVoltage * 100, 350, 420, 0, 100);
    
    if (batteryPercentage < 0) batteryPercentage = 0;
    if (batteryPercentage > 100) batteryPercentage = 100;

    // Bluetooth Stream for Flutter & Serial Monitor
    Serial.print("Temp: ");   Serial.print(t, 1);
    Serial.print("C Humidity: "); Serial.print(h, 1);
    Serial.print("% CO: ");      
    if (isSensorReady) {
      Serial.print(coPpm);
    } else {
      Serial.print("Warming..."); 
    }
    Serial.print("PPM Bat: "); 
    Serial.print(batteryPercentage); // Sending real-time battery percentage
    Serial.print("%\n");
  }

  // 3. BACKGROUND STORAGE (Every 5 Minutes)
  if (isSensorReady && (currentTime - lastBackupSaveTime >= backupInterval)) {
    lastBackupSaveTime = currentTime;

    float h = dht.readHumidity();
    float t = dht.readTemperature();
    int rawAnalog = analogRead(mq7Pin);
    
    if (isnan(h) || isnan(t)) { t = 0.0; h = 0.0; }
    
    if (rawAnalog < 40) rawAnalog = 40;
    if (rawAnalog > 800) rawAnalog = 800;
    
    int coPpm = map(rawAnalog, 40, 800, 0, 500);
    if (coPpm < 0) coPpm = 0;
    if (coPpm > 500) coPpm = 500;

    if (totalSavedPoints >= maxBackupPoints) {
      for (int i = 0; i < maxBackupPoints - 1; i++) {
        backupCO[i] = backupCO[i + 1];
        backupTemp[i] = backupTemp[i + 1];
        backupHum[i] = backupHum[i + 1];
      }
      totalSavedPoints = maxBackupPoints - 1;
    }

    backupCO[totalSavedPoints] = coPpm;
    backupTemp[totalSavedPoints] = (byte)t; 
    backupHum[totalSavedPoints] = (byte)h;  
    totalSavedPoints++;
  }
}