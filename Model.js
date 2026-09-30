// Names, glyphs and menu rows for the input menu. Qt-free so node can test it
// (test/model-check.js). Everything is keyed by fcitx5 icon names, never by
// label text, because fcitx5 translates labels.

// Quickshell hands icons over as image://icon/<name>[?path=…], or as a file
// path for pixmaps. Either way the name is what identifies the mode.
function parseIconUrl(url) {
  var s = String(url || "")
  if (s.indexOf("image://icon/") === 0) s = s.slice("image://icon/".length)
  var q = s.indexOf("?")
  if (q >= 0) s = s.slice(0, q)
  if (s.indexOf("file://") === 0) s = s.slice("file://".length)
  if (s.indexOf("/") >= 0) s = s.slice(s.lastIndexOf("/") + 1).replace(/\.(png|svg|xpm)$/, "")
  return s
}

function localeKey(name) {
  var s = String(name || "").replace("-", "_")
  if (/^zh_(TW|HK|MO|Hant)/.test(s)) return "zh-TW"
  if (/^ja/.test(s)) return "ja"
  return "en"
}

var KNOWN = {
  "fcitx-chewing":            { glyph: "ㄅ", en: "Zhuyin", "zh-TW": "注音", ja: "注音" },
  "fcitx_mozc":               { glyph: "あ", en: "Japanese", "zh-TW": "日文", ja: "日本語" },
  "fcitx_mozc_hiragana":      { glyph: "あ", en: "Hiragana", "zh-TW": "平假名", ja: "ひらがな" },
  "fcitx_mozc_katakana_full": { glyph: "ア", en: "Katakana", "zh-TW": "片假名", ja: "カタカナ" },
  "fcitx_mozc_alpha_half":    { glyph: "A", en: "Romaji", "zh-TW": "英數", ja: "英数" },
  "fcitx_mozc_alpha_full":    { glyph: "Ａ", en: "Full-width Romaji", "zh-TW": "全形英數", ja: "全角英数" },
  "fcitx_mozc_katakana_half": { glyph: "ｱ", en: "Half-width Katakana", "zh-TW": "半形片假名", ja: "半角カタカナ" },
  "fcitx_mozc_direct":        { glyph: "A", en: "Direct", "zh-TW": "直接輸入", ja: "直接入力" }
}
var ABC = { glyph: "A", en: "ABC", "zh-TW": "ABC", ja: "ABC" }

var DEFAULT_HIDDEN_MODES = ["fcitx_mozc_direct", "fcitx_mozc_alpha_full", "fcitx_mozc_katakana_half"]

function isKeyboard(icon) {
  var s = String(icon || "")
  return s === "input-keyboard" || s === "input-keyboard-symbolic" || s.indexOf("fcitx-keyboard") === 0
}

function known(icon) {
  if (isKeyboard(icon)) return ABC
  return KNOWN[String(icon || "")] || null
}

function glyphFor(icon, label) {
  var k = known(icon)
  if (k) return k.glyph
  var c = String(label || "").trim().charAt(0)
  return c ? c.toUpperCase() : "?"
}

function titleFor(icon, locale, text) {
  var k = known(icon)
  if (k) return k[localeKey(locale)] || k.en
  return String(text || "") || String(icon || "")
}

function rows(ims, modeCache, hidden, currentMode, locale) {
  var out = []
  var cache = modeCache || {}
  var hide = hidden || []
  ;(ims || []).forEach(function (im) {
    var cached = cache[im.icon]
    var modes = (Array.isArray(cached) ? cached : []).filter(function (m) {
      return m && typeof m.icon === "string" && hide.indexOf(m.icon) === -1
    })
    if (modes.length === 0) {
      out.push({ im: im.icon, mode: "", glyph: glyphFor(im.icon, im.text), title: titleFor(im.icon, locale, im.text), checked: !!im.checked })
      return
    }
    modes.forEach(function (m) {
      out.push({ im: im.icon, mode: m.icon, glyph: glyphFor(m.icon, m.text), title: titleFor(m.icon, locale, m.text),
                 checked: !!im.checked && m.icon === currentMode })
    })
  })
  return out
}

var STRINGS = {
  en: {
    onlyOne: "Only one input method is set up", addIm: "Add Input Method…",
    emoji: "Emoji & Symbols", settings: "Open Input Method Settings…", matchTheme: "Match Omarchy Theme…",
    notRunning: "Input method is not running", start: "Start Input Method",
    sniOff: "Input Menu can't see fcitx5 yet", enable: "Enable Input Menu…",
    switchFailed: "Couldn't switch input method"
  },
  "zh-TW": {
    onlyOne: "目前只設定了一種輸入法", addIm: "加入輸入法⋯",
    emoji: "表情與符號", settings: "打開輸入法設定⋯", matchTheme: "套用 Omarchy 主題色…",
    notRunning: "輸入法沒有在執行", start: "啟動輸入法",
    sniOff: "Input Menu 還讀不到 fcitx5", enable: "啟用 Input Menu⋯",
    switchFailed: "無法切換輸入法"
  },
  ja: {
    onlyOne: "入力メソッドが1つしか設定されていません", addIm: "入力メソッドを追加…",
    emoji: "絵文字と記号", settings: "入力メソッドの設定を開く…", matchTheme: "Omarchy テーマに合わせる…",
    notRunning: "入力メソッドが実行されていません", start: "入力メソッドを起動",
    sniOff: "Input Menu が fcitx5 を読み取れません", enable: "Input Menu を有効にする…",
    switchFailed: "入力メソッドを切り替えられませんでした"
  }
}

function strings(locale) {
  return STRINGS[localeKey(locale)] || STRINGS.en
}

// QML's url is not a C++ QUrl, so toLocalFile() is unavailable there.
function localFilePath(url) {
  var value = String(url)
  return value.indexOf("file:///") === 0 ? decodeURIComponent(value.slice("file://".length)) : ""
}

// The presentation launcher runs its joined arguments via bash -c.
function shellQuote(path) {
  return "'" + String(path).replace(/'/g, "'\\''") + "'"
}

if (typeof module !== "undefined") {
  module.exports = { parseIconUrl: parseIconUrl, localeKey: localeKey, glyphFor: glyphFor, titleFor: titleFor,
                     isKeyboard: isKeyboard, rows: rows, strings: strings, localFilePath: localFilePath, shellQuote: shellQuote, DEFAULT_HIDDEN_MODES: DEFAULT_HIDDEN_MODES }
}
