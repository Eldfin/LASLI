package com.afonsoraposo.bitalino;

import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Parcelable;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Set;

import info.plux.pluxapi.Communication;
import info.plux.pluxapi.Constants;
import info.plux.pluxapi.bitalino.BITalinoCommunication;
import info.plux.pluxapi.bitalino.BITalinoCommunicationFactory;
import info.plux.pluxapi.bitalino.BITalinoDescription;
import info.plux.pluxapi.bitalino.BITalinoErrorTypes;
import info.plux.pluxapi.bitalino.BITalinoException;
import info.plux.pluxapi.bitalino.BITalinoFrame;
import info.plux.pluxapi.bitalino.BITalinoState;
import info.plux.pluxapi.bitalino.bth.OnBITalinoDataAvailable;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.Result;


final class BITalino implements MethodChannel.MethodCallHandler {
    private final Activity activity;
    private final MethodChannel methodChannel;
    private final EventChannel dataStreamChannel;
    private BITalinoCommunication bitalinoCommunication;
    private Result descriptionResult;
    private Result stateResult;
    private Result connectResult;
    private Result disconnectResult;
    private Result startResult;
    private Result stopResult;
    private EventChannel.EventSink dataStreamSink;
    private boolean receiverRegistered = false;


    BITalino(Activity activity, BinaryMessenger messenger) {
        this.activity = activity;

        methodChannel = new MethodChannel(messenger, "com.afonsoraposo.bitalino/bitalino");
        dataStreamChannel = new EventChannel(messenger, "com.afonsoraposo.bitalino/dataStream");
        methodChannel.setMethodCallHandler(this);
    }

    private final BroadcastReceiver updateReceiver = new BroadcastReceiver() {  @Override
        public void onReceive(Context context, Intent intent) {
            final String action = intent.getAction();
            if (Constants.ACTION_STATE_CHANGED.equals(action)) {
                String identifier = intent.getStringExtra(Constants.IDENTIFIER);
                Constants.States state = Constants.States.getStates(intent.getIntExtra(Constants.EXTRA_STATE_CHANGED,0));
                //Log.i(TAG, "Device " + identifier + ": " + state.name());
                switch (state.name()){
                    case "CONNECTED":
                        if(connectResult!=null){
                            connectResult.success(true);
                            connectResult = null;
                        }
                        if(stopResult!=null){
                            stopResult.success(true);
                            stopResult=null;
                        }
                        break;
                    case "DISCONNECTED":
                        if(disconnectResult!=null){
                            failPendingRequests("BITalino disconnected.");
                            disconnectResult.success(true);
                            disconnectResult = null;
                        }else{
                            if(connectResult!=null){
                                connectResult.success(false);
                                connectResult = null;
                            }else{
                                failPendingRequests("BITalino disconnected.");
                                methodChannel.invokeMethod("lostConnection", null);
                            }
                        }
                        break;
                    case "ACQUISITION_OK":
                        if(startResult!=null){
                            startResult.success(true);
                            startResult = null;
                        }
                        break;
                    default:
                        break;
                }
            } else if (Constants.ACTION_DATA_AVAILABLE.equals(action)) {
                BITalinoFrame frame = intent.getParcelableExtra(Constants.EXTRA_DATA);
                sendToDataStreamChannel(frame);
            } else if (Constants.ACTION_COMMAND_REPLY.equals(action)) {
                String identifier = intent.getStringExtra(Constants.IDENTIFIER);
                Parcelable parcelable = intent.getParcelableExtra(Constants.EXTRA_COMMAND_REPLY);
                if(parcelable.getClass().equals(BITalinoState.class)){
                    //Log.d(TAG, "BITalinoState: " + parcelable.toString());
                    if(stateResult!=null){
                        BITalinoState state = ((BITalinoState) parcelable);
                        final Map<String, Object> dataBuffer = new HashMap<>();
                        dataBuffer.put("identifier", state.getIdentifier());
                        dataBuffer.put("battery", state.getBattery());
                        dataBuffer.put("batteryThreshold", state.getBatThreshold());
                        dataBuffer.put("analog", state.getAnalogArray());
                        dataBuffer.put("digital", state.getDigitalArray());
                        stateResult.success(dataBuffer);
                        stateResult = null;
                    }
                } else if(parcelable.getClass().equals(BITalinoDescription.class)){
                    //Log.d(TAG,  "BITalinoDescription: isBITalino2: " + ((BITalinoDescription)parcelable).isBITalino2() +  "; FwVersion: " + ((BITalinoDescription)parcelable).getFwVersion());
                    if(descriptionResult!=null){
                        BITalinoDescription description = (BITalinoDescription)parcelable;
                        final Map<String, Object> dataBuffer = new HashMap<>();
                        dataBuffer.put("isBITalino2", description.isBITalino2());
                        dataBuffer.put("fwVersion", ""+description.getFwVersion());
                        descriptionResult.success(dataBuffer);
                        descriptionResult = null;
                    }
                }
            } else if (Constants.ACTION_MESSAGE_SCAN.equals(action)){
                BluetoothDevice device = intent.getParcelableExtra(Constants.EXTRA_DEVICE_SCAN);
            }
        }
    };

    protected static IntentFilter updateIntentFilter() {
        final IntentFilter intentFilter = new IntentFilter();
        intentFilter.addAction(Constants.ACTION_STATE_CHANGED);
        intentFilter.addAction(Constants.ACTION_DATA_AVAILABLE);
        intentFilter.addAction(Constants.ACTION_COMMAND_REPLY);
        intentFilter.addAction(Constants.ACTION_MESSAGE_SCAN);
        return intentFilter;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull final Result result) {
        switch (call.method) {
            case "scanDevices":
                try {
                    final int type = call.argument("type");
                    result.success(scanBitalinoDevices(type));
                } catch (SecurityException e) {
                    e.printStackTrace();
                    result.error("BluetoothPermission", e.getMessage(), null);
                } catch (Exception e) {
                    e.printStackTrace();
                    result.error("BITalinoScan", e.getMessage(), null);
                }
                break;
            case "initialize":
                try {
                    if(call.argument("type")!=null) {
                        final int type = call.argument("type");
                        final Communication communication = Communication.getById(type);
                        if (type == 1) {
                            bitalinoCommunication = new BITalinoCommunicationFactory().getCommunication(
                                    communication, activity.getBaseContext(), new OnBITalinoDataAvailable() {
                                        @Override
                                        public void onBITalinoDataAvailable(BITalinoFrame bitalinoFrame) {
                                            try {
                                                sendToDataStreamChannel(bitalinoFrame);
                                            } catch (Exception e) {
                                                e.printStackTrace();
                                            }
                                        }
                                    });
                        } else if (type == 2) {
                            bitalinoCommunication = new BITalinoCommunicationFactory().getCommunication(
                                    communication, activity.getBaseContext());
                        }
                        startDataStream(dataStreamChannel);
                        registerUpdateReceiver();
                        result.success(true);
                    }else{
                        throw new Exception("A valid bluetooth connection type must be provided.");
                    }
                } catch (Exception e) {
                    e.printStackTrace();
                    result.error("BITalinoCommunicationFactory", e.getMessage(), null);
                }
                break;
            case "connect":
                try {
                    connectResult = result;
                    if(!bitalinoCommunication.connect((String) call.argument("address"))){
                        throw new BITalinoException(BITalinoErrorTypes.BT_DEVICE_NOT_CONNECTED);
                    }
                } catch (BITalinoException e) {
                    connectResult = null;
                    e.printStackTrace();
                    result.error("BITalinoCommunication", e.getMessage(), null);
                }
                break;
            case "disconnect":
                try {
                    disconnectResult = result;
                    bitalinoCommunication.disconnect();
                } catch (BITalinoException e) {
                    disconnectResult = null;
                    e.printStackTrace();
                    result.error("BITalinoCommunication",e.getMessage(), null);
                }
                break;
            case "dispose":
                try {
                    if (bitalinoCommunication != null) {
                        bitalinoCommunication.closeReceivers();
                    }
                    unregisterUpdateReceiver();
                    cancelDataStreamSink();
                    bitalinoCommunication = null;
                    result.success(true);
                } catch (Exception e) {
                    e.printStackTrace();
                    result.error("BITalinoCommunication",e.getMessage(), null);
                }
                break;
            case "description":
                try {
                    descriptionResult = result;
                    bitalinoCommunication.getVersion();
                } catch (BITalinoException e) {
                    descriptionResult = null;
                    e.printStackTrace();
                    result.error("BITalinoCommunication",e.getMessage(), null);
                }
                break;
            case "state":
                try {
                    stateResult = result;
                    if(!bitalinoCommunication.state()){
                        throw new BITalinoException(BITalinoErrorTypes.UNDEFINED);
                    }
                } catch (BITalinoException e) {
                    stateResult = null;
                    e.printStackTrace();
                    result.error("BITalinoCommunication", e.getMessage(), null);
                }
                break;
            case "batteryThreshold":
                try{
                    final int threshold = call.argument("threshold");
                    result.success(bitalinoCommunication.battery(threshold));
                } catch (BITalinoException e) {
                    e.printStackTrace();
                    result.error("BITalinoCommunication", e.getMessage(), null);
                }
                break;
            case "start":
                try{
                    final ArrayList<Integer> channels = call.argument("analogChannels");
                    final int sampleRate = call.argument("sampleRate");
                    startResult = result;
                    if(!bitalinoCommunication.start(convertIntegers(channels), sampleRate)){
                        startResult=null;
                        result.success(false);
                    }
                } catch (BITalinoException e) {
                    startResult = null;
                    e.printStackTrace();
                    result.error("BITalinoCommunication", e.getMessage(), null);
                }
                break;
            case "stop":
                try{
                    stopResult = result;
                    if(!bitalinoCommunication.stop()) { // for some reason, the code returns false if sent successfully
                        stopResult = null;
                        result.success(false);
                    }
                }catch(BITalinoException e) {
                    stopResult = null;
                    e.printStackTrace();
                    result.error("BITalinoCommunication", e.getMessage(), null);
                }
                break;
            case "trigger":
                try{
                    final ArrayList<Integer> channels = call.argument("digitalChannels");
                    result.success(bitalinoCommunication.trigger(convertIntegers(channels)));
                } catch (BITalinoException e) {
                    e.printStackTrace();
                    result.error("BITalinoCommunication", e.getMessage(), null);
                }
                break;
            case "pwm":
                try{
                    final int pwmOutput = call.argument("pwmOutput");
                    result.success(bitalinoCommunication.pwm(pwmOutput));
                } catch (BITalinoException e) {
                    e.printStackTrace();
                    result.error("BITalinoCommunication", e.getMessage(), null);
                }
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    void stopListening() {
        unregisterUpdateReceiver();
        dataStreamChannel.setStreamHandler(null);
        methodChannel.setMethodCallHandler(null);
    }

    void startDataStream(final EventChannel dataStreamChannel){
        dataStreamChannel.setStreamHandler(
        new EventChannel.StreamHandler() {
          @Override
          public void onListen(Object o, EventChannel.EventSink dataStreamSink) {
            setDataStreamSink(dataStreamSink);
          }

          @Override
          public void onCancel(Object o) {
              cancelDataStreamSink();
          }
        });
    }

    private void setDataStreamSink(EventChannel.EventSink dataStreamSink){
        this.dataStreamSink = dataStreamSink;
    }

    private void cancelDataStreamSink(){
        this.dataStreamSink = null;
    }

    private void failPendingRequests(String message) {
        if (descriptionResult != null) {
            descriptionResult.error("BITalinoCommunication", message, null);
            descriptionResult = null;
        }
        if (stateResult != null) {
            stateResult.error("BITalinoCommunication", message, null);
            stateResult = null;
        }
        if (startResult != null) {
            startResult.success(false);
            startResult = null;
        }
        if (stopResult != null) {
            stopResult.success(false);
            stopResult = null;
        }
    }

    private void registerUpdateReceiver() {
        if (receiverRegistered) {
            return;
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(
                    updateReceiver,
                    updateIntentFilter(),
                    Context.RECEIVER_NOT_EXPORTED);
        } else {
            activity.registerReceiver(updateReceiver, updateIntentFilter());
        }
        receiverRegistered = true;
    }

    private void unregisterUpdateReceiver() {
        if (!receiverRegistered) {
            return;
        }

        try {
            activity.unregisterReceiver(updateReceiver);
        } catch (IllegalArgumentException e) {
            e.printStackTrace();
        } finally {
            receiverRegistered = false;
        }
    }

    void sendToDataStreamChannel(BITalinoFrame frame){
        if(dataStreamSink!=null) {
            final Map<String, Object> dataBuffer = new HashMap<>();
            dataBuffer.put("identifier", frame.getIdentifier());
            dataBuffer.put("sequence", frame.getSequence());
            dataBuffer.put("analog", frame.getAnalogArray());
            dataBuffer.put("digital", frame.getDigitalArray());
            activity.runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    dataStreamSink.success(dataBuffer);
                }
            });
        }
    }

    public static int[] convertIntegers(List<Integer> integers)
    {
        int[] ret = new int[integers.size()];
        Iterator<Integer> iterator = integers.iterator();
        for (int i = 0; i < ret.length; i++)
        {
            ret[i] = iterator.next().intValue();
        }
        return ret;
    }

    private List<Map<String, Object>> scanBitalinoDevices(int type) {
        final List<Map<String, Object>> devices = new ArrayList<>();
        final BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter == null || !adapter.isEnabled()) {
            return devices;
        }

        final Set<BluetoothDevice> bondedDevices = adapter.getBondedDevices();
        for (BluetoothDevice device : bondedDevices) {
            final String name = device.getName();
            if (isBitalinoDevice(name)) {
                final Map<String, Object> data = new HashMap<>();
                data.put("name", name);
                data.put("address", device.getAddress());
                data.put("type", type);
                data.put("bonded", true);
                devices.add(data);
            }
        }
        return devices;
    }

    private boolean isBitalinoDevice(String name) {
        return name != null && name.toLowerCase().contains("bitalino");
    }

}
