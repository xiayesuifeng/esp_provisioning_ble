import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_ble_lib_ios_15/flutter_ble_lib.dart';
import 'package:logger/logger.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart' as geo;

part 'ble_event.dart';
part 'ble_state.dart';

class BleBloc extends Bloc<BleEvent, BleState> {
  static DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  static BleManager bleManager = BleManager();
  late StreamSubscription streamSubscriptionLocationStatus;
  static geo.GeolocatorPlatform locator = geo.GeolocatorPlatform.instance;

  var logger = Logger();
  int? androidSdkVersion;
  List<Map<String,dynamic>> discoveredDevices = [];

  BleBloc() : super(BleInitialState()) {
    on<BleInitialEvent>((event, emit) async {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      androidSdkVersion = androidInfo.version.sdkInt;
      logger.d("Android version: $androidSdkVersion");
      add(BleStatusEvent());
    });

    on<BleStatusEvent>((event, emit) async {
      try {
        await bleManager.createClient();
        //TODO: remeber to destroy client;
      } catch (e) {
        logger.e("Error creating ble Manager client", error: e);
      }
      bleManager.observeBluetoothState().listen((btState) {
        logger.d(btState);
        if (btState == BluetoothState.POWERED_ON) {
          add(BleEnabledEvent());
        } else {
          add(BleDisabledEvent());
        }
      });
    });

    on<BleViewHiddenEvent>((event, emit) {
      //TODO: fix the request on background, i just want on foreground
    });

    on<BleEnabledEvent>((event, emit) {
      emit(BleEnableState());
      if (androidSdkVersion! > 30) {
        add(BlePermissionStatusEvent());
      } else {
        add(LocationStatusEvent());
      }
    });

    on<BleDisabledEvent>((event, emit) => emit(BleDisabledState()));

    on<BlePermissionStatusEvent>((event, emit) async {
      PermissionStatus blePermissionScan = (event.permissionbleStatus != null)
          ? event.permissionbleStatus!
          : await Permission.bluetoothScan.status;
      logger.d("Permission to Scan: $blePermissionScan");
      switch (blePermissionScan) {
        case PermissionStatus.granted:
          emit(BlePermissionEnableState());
          add(BleReadytoScanEvent());
        case PermissionStatus.denied:
          emit(BlePermissionDeniedState());
          add(BlePermissionRequestEvent());
        case PermissionStatus.restricted:
          // Only supported on iOS.
          emit(BlePermissionDeniedState());
          add(BlePermissionRequestEvent());
        case PermissionStatus.limited:
          //Only supported on iOS (iOS14+).
          emit(BlePermissionDeniedState());
          add(BlePermissionRequestEvent());
        case PermissionStatus.permanentlyDenied:
          emit(BlePermissionDeniedForever());
        case PermissionStatus.provisional:
          //Only supported on iOS (iOS12+)
          emit(BlePermissionDeniedState());
          add(BlePermissionRequestEvent());
      }
    });

    on<BlePermissionRequestEvent>((event, emit) async {
      var blepermissionRequest = await Permission.bluetoothScan.request();
      add(BlePermissionStatusEvent(permissionbleStatus: blepermissionRequest));
    });

    on<LocationStatusEvent>((event, emit) async {
      bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
      if (serviceEnabled) {
        add(LocationEnabledEvent());
      } else {
        add(LocationDisabledEvent());
      }
      Stream streamLocation =
          locator.getServiceStatusStream().asBroadcastStream();

      streamSubscriptionLocationStatus = streamLocation.listen((status) async {
        if (status == geo.ServiceStatus.enabled) {
          add(LocationEnabledEvent());
        } else {
          add(LocationDisabledEvent());
        }
      });
    });

    on<LocationEnabledEvent>(((event, emit) {
      emit(LocationEnable());
      add(LocationPermissionStatusEvent());
    }));

    on<LocationDisabledEvent>(((event, emit) => emit(LocationDisabled())));

    on<LocationPermissionStatusEvent>((event, emit) async {
      geo.LocationPermission permission =
          (event.permissionLocationStatus != null)
              ? event.permissionLocationStatus!
              : await geo.Geolocator.checkPermission();
      switch (permission) {
        case geo.LocationPermission.always:
          add(BleReadytoScanEvent());
        case geo.LocationPermission.whileInUse:
          add(BleReadytoScanEvent());
        case geo.LocationPermission.denied:
          emit(PermissionLocationDenied());
          add(LocationPermissionRequestEvent());
        case geo.LocationPermission.deniedForever:
          emit(PermissionLocationDeniedForever());
          add(LocationPermissionRequestEvent());
        case geo.LocationPermission.unableToDetermine:
          emit(PermissionLocationUnableToDetermine());
          add(LocationPermissionRequestEvent());
        default:
          emit(PermissionLocationUnableToDetermine());
          add(LocationPermissionRequestEvent());
      }
    });

    on<LocationPermissionRequestEvent>((event, emit) async {
      geo.LocationPermission permissionStatus =
          await geo.Geolocator.requestPermission();
      add(LocationPermissionStatusEvent(
          permissionLocationStatus: permissionStatus));
    });

    on<BleReadytoScanEvent>((event, emit) async {
      emit(BleReadytoScan());
      await Permission.bluetoothConnect.request();
      add(BleScanningEvent(prefix: "PROV_"));
    });

    on<BleScanningEvent>((event, emit) {
      String prefix = (event.prefix != null) ? event.prefix! : "";
      emit(BleScanning());
      bleManager.startPeripheralScan().listen((scanResult) {
        Peripheral peripheral = scanResult.peripheral;
        logger.d(
          "Scanned Peripheral ${peripheral.name}, \n RSSI ${scanResult.rssi}",
        );
        Map<String, dynamic> peripheralMap = {
          "name": peripheral.name,
          "instance": peripheral,
        };
        bool hasInTheList = false;
        if (peripheral.name != null) {
          if (peripheral.name!.contains(prefix)) {
            for (var obj in discoveredDevices) {
              if (obj['name'] == peripheral.name) {
                hasInTheList = true;
              }
            }
            if (!hasInTheList) {
              discoveredDevices.add(peripheralMap);
            }
          }
        }
        add(BleScanCompletedEvent(devices: discoveredDevices));
      });
    });

    on<BleStopScanEvent>((event, emit) async {
      emit(BleStopScan());
          bleManager.stopPeripheralScan();
          logger.d(
          "DISCOVERED DEVICES LIST: $discoveredDevices",
        );
    });

    on<BleRestartingScanEvent>((event, emit) async {
      discoveredDevices.clear();
      add(BleScanningEvent(prefix: event.prefix));
    });

    on<BleScanCompletedEvent>((event, emit) {
      if (event.devices.isNotEmpty) {
        emit(BleScanCompleted(foundedDevices: event.devices));
      }else{
        emit(BleEmptyList());
      }
    });
  }
}
