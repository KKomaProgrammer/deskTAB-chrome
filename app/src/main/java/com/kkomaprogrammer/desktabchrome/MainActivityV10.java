package com.kkomaprogrammer.desktabchrome;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

/**
 * Keeps the mature MainActivity behavior while correcting the user-visible engine/version
 * labels for the v10 zstd installer without duplicating the entire controller.
 */
public class MainActivityV10 extends MainActivity {
    private final Handler patchHandler = new Handler(Looper.getMainLooper());
    private final Runnable patcher = new Runnable() {
        @Override public void run() {
            View root = getWindow() == null ? null : getWindow().getDecorView();
            if (root != null) patchTree(root);
            patchHandler.postDelayed(this, 350);
        }
    };

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        patchHandler.post(patcher);
    }

    @Override protected void onStart() {
        super.onStart();
        patchHandler.removeCallbacks(patcher);
        patchHandler.post(patcher);
    }

    @Override protected void onStop() {
        patchHandler.removeCallbacks(patcher);
        super.onStop();
    }

    private void patchTree(View v) {
        if (v instanceof TextView) {
            TextView tv = (TextView) v;
            CharSequence cs = tv.getText();
            if (cs != null) {
                String s = cs.toString();
                if (s.startsWith("v1.2.15는 불완전 manifest")) {
                    tv.setText("v1.2.16은 xz 대신 zstd 런타임을 사용해 82% 이미지 해제를 대폭 단축합니다. 해제 진행률·실시간 ETA·120초 무진행 감시·사전 저장공간 검사와 Chrome/XFCE/필수 패키지 전체 검증 후에만 기존 환경을 교체합니다.");
                } else {
                    String n = s.replace("heartbeat v9", "heartbeat v10")
                            .replace("v9은 중복 실행", "v10은 중복 실행")
                            .replace("완성 XZ SHA", "완성 zstd SHA");
                    if (!n.equals(s)) tv.setText(n);
                }
            }
        }
        if (v instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); i++) patchTree(g.getChildAt(i));
        }
    }
}
