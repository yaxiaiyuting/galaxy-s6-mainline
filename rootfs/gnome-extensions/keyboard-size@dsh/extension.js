/*
 * G9209: 放大屏幕键盘按键
 *
 * GNOME Shell 43 的 ui/keyboard.js 里：
 *   _relayout() {
 *       ...
 *       if (monitor.width > monitor.height)
 *           this.height = monitor.height / 3;
 *       else
 *           this.height = monitor.height / 4;     ← 竖屏走这条
 *   }
 * 在 720x1280 逻辑分辨率下，键盘总高只有 320px，按键很小（~30px）。
 *
 * 本扩展在运行时替换 _relayout，把分母从 4 改小（默认 2.2 → 高度 582px，
 * 按键约 1.8 倍大）。不修改任何系统文件，禁用扩展即恢复原状。
 *
 * 想再调大/调小：改下面的 DIVISOR 然后 Alt+F2 → r 重启 Shell。
 */
'use strict';

const { GLib, Gio } = imports.gi;
const Main = imports.ui.main;
const Keyboard = imports.ui.keyboard;

// 竖屏高度分母：越小按键越大。原值 4。建议范围 1.8 ~ 3.0
const DIVISOR_PORTRAIT = 2.2;
// 横屏分母：原值 3
const DIVISOR_LANDSCAPE = 2.6;

let _originalRelayout = null;

class KeyboardSizeExtension {
    constructor() {
        this._settings = null;
    }

    enable() {
        const proto = Keyboard.Keyboard.prototype;

        if (_originalRelayout === null)
            _originalRelayout = proto._relayout;

        const divisorPortrait = DIVISOR_PORTRAIT;
        const divisorLandscape = DIVISOR_LANDSCAPE;

        proto._relayout = function () {
            let monitor = Main.layoutManager.keyboardMonitor;
            if (!monitor)
                return;

            this.width = monitor.width;
            if (monitor.width > monitor.height)
                this.height = monitor.height / divisorLandscape;
            else
                this.height = monitor.height / divisorPortrait;

            /* 触发一次尺寸变化让按键重新排布 */
            if (this.notify)
                this.notify('height');
        };

        log('[keyboard-size] enabled: portrait /' + divisorPortrait +
            ', landscape /' + divisorLandscape);
    }

    disable() {
        if (_originalRelayout !== null) {
            Keyboard.Keyboard.prototype._relayout = _originalRelayout;
            _originalRelayout = null;
        }
        log('[keyboard-size] disabled');
    }
}

function init() {
    return new KeyboardSizeExtension();
}
