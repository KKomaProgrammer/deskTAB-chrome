package com.kkomaprogrammer.desktabchrome;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class SetupDoneReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if ("com.kkomaprogrammer.desktabchrome.SETUP_DONE".equals(intent.getAction())) {
            context.getSharedPreferences("state", Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean("ready", true)
                    .putBoolean("setup_running", false)
                    .apply();
        }
    }
}
