package com.afonsoraposo.bitalino;

import android.app.Activity;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;

/** BitalinoPlugin */
public class BitalinoPlugin implements FlutterPlugin, ActivityAware {
    private @Nullable
    FlutterPluginBinding flutterPluginBinding;
    private @Nullable BITalino bitalino;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        this.flutterPluginBinding = binding;
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        this.flutterPluginBinding = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        if (flutterPluginBinding == null) {
            return;
        }
        startListening(binding.getActivity(), flutterPluginBinding.getBinaryMessenger());
    }

    @Override
    public void onDetachedFromActivity() {
        if (bitalino == null) {
            return;
        }

        bitalino.stopListening();
        bitalino = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    private void startListening(Activity activity, BinaryMessenger messenger) {
        bitalino = new BITalino(activity, messenger);
    }
}
