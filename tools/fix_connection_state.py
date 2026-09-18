from pathlib import Path

p = Path('app/src/main/java/com/kkomaprogrammer/desktabchrome/LauncherActivity.java')
s = p.read_text(encoding='utf-8')

needle = '''    private void refreshUi() {\n        if (primaryButton == null) return;\n        boolean termux = installed(TERMUX);\n        boolean x11 = installed(X11);\n        boolean permission = checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED;\n        boolean bridge = prefs.getBoolean("termux_bridge_ready", false);\n'''
replacement = '''    private boolean isTermuxConnected() {\n        boolean termux = installed(TERMUX);\n        boolean permission = checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED;\n        if (!termux || !permission) {\n            if (prefs.getBoolean("termux_bridge_ready", false)) {\n                prefs.edit().putBoolean("termux_bridge_ready", false).apply();\n            }\n            return false;\n        }\n        if (prefs.getBoolean("termux_bridge_ready", false)) return true;\n        if (probeTermuxBridge()) {\n            prefs.edit()\n                    .putBoolean("termux_bridge_ready", true)\n                    .putString("termux_last_error", "")\n                    .apply();\n            return true;\n        }\n        return false;\n    }\n\n    private void refreshUi() {\n        if (primaryButton == null) return;\n        boolean termux = installed(TERMUX);\n        boolean x11 = installed(X11);\n        boolean permission = checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED;\n        boolean bridge = isTermuxConnected();\n'''
assert needle in s, 'refreshUi target not found'
s = s.replace(needle, replacement, 1)

old = '''        if (!prefs.getBoolean("termux_bridge_ready", false)) {\n            connectTermux(true);\n            return;\n        }\n'''
new = '''        if (!isTermuxConnected()) {\n            connectTermux(true);\n            return;\n        }\n'''
assert old in s, 'primary action bridge target not found'
s = s.replace(old, new, 1)

start = s.index('    private void showSettings() {')
end = s.index('    private void upgradeX11Performance()', start)
new_method = '''    private void showSettings() {\n        boolean connected = isTermuxConnected();\n        java.util.ArrayList<String> items = new java.util.ArrayList<>();\n        items.add("Termux:X11 성능 최적화");\n        items.add("필수 구성 설치/복구");\n        if (!connected) items.add("Termux 연결");\n        items.add("Linux 환경 복구");\n        items.add("데스크톱 세션 종료");\n        items.add("진단");\n\n        String[] labels = items.toArray(new String[0]);\n        new AlertDialog.Builder(this)\n                .setTitle("설정")\n                .setItems(labels, (d, which) -> {\n                    String item = labels[which];\n                    if ("Termux:X11 성능 최적화".equals(item)) {\n                        upgradeX11Performance();\n                    } else if ("필수 구성 설치/복구".equals(item)) {\n                        startDependencyInstall();\n                    } else if ("Termux 연결".equals(item)) {\n                        connectTermux(false);\n                    } else if ("Linux 환경 복구".equals(item)) {\n                        prefs.edit().putBoolean("ready", false).putString("termux_last_error", "").apply();\n                        runBootstrap();\n                    } else if ("데스크톱 세션 종료".equals(item)) {\n                        stopDesktop();\n                    } else if ("진단".equals(item)) {\n                        showDiagnostics();\n                    }\n                })\n                .setNegativeButton("닫기", null)\n                .show();\n    }\n\n'''
s = s[:start] + new_method + s[end:]

old_diag = '''        String text = "Termux: " + (installed(TERMUX) ? "정상" : "설치 필요") +\n                "\\nTermux:X11: " + (installed(X11) ? "정상" : "설치 필요") +\n                "\\nX11 고속 모드: " + (x11SharesUid() ? "적용" : "미적용") +\n                "\\n명령 권한: " + (checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED ? "정상" : "허용 필요") +\n                "\\n연결: " + (prefs.getBoolean("termux_bridge_ready", false) ? "정상" : "확인 필요") +\n'''
new_diag = '''        boolean connected = isTermuxConnected();\n        String text = "Termux: " + (installed(TERMUX) ? "정상" : "설치 필요") +\n                "\\nTermux:X11: " + (installed(X11) ? "정상" : "설치 필요") +\n                "\\nX11 고속 모드: " + (x11SharesUid() ? "적용" : "미적용") +\n                "\\n명령 권한: " + (checkSelfPermission(RUN_PERMISSION) == PackageManager.PERMISSION_GRANTED ? "정상" : "허용 필요") +\n                "\\n연결: " + (connected ? "정상" : "확인 필요") +\n'''
assert old_diag in s, 'diagnostics target not found'
s = s.replace(old_diag, new_diag, 1)

# Re-check connection immediately on resume using the same source of truth.
old_resume = '''        syncHeartbeatFromTermux();\n        refreshUi();\n    }\n\n    private View buildUi() {\n'''
new_resume = '''        isTermuxConnected();\n        syncHeartbeatFromTermux();\n        refreshUi();\n    }\n\n    private View buildUi() {\n'''
assert old_resume in s, 'resume target not found'
s = s.replace(old_resume, new_resume, 1)

p.write_text(s, encoding='utf-8')
print('patched LauncherActivity.java')
