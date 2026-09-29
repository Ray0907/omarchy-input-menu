// Failure cases for Model.js, written before Model.js. Run: node test/model-check.js
const assert = require("assert")
const M = require("../Model.js")

// Icon URLs: Quickshell gives image://icon/<name>, sometimes with ?path=; pixmaps come as files.
assert.strictEqual(M.parseIconUrl("image://icon/fcitx_mozc_hiragana"), "fcitx_mozc_hiragana")
assert.strictEqual(M.parseIconUrl("image://icon/fcitx-chewing?path=/usr/share/icons"), "fcitx-chewing")
assert.strictEqual(M.parseIconUrl("file:///usr/share/icons/hicolor/48x48/apps/fcitx-chewing.png"), "fcitx-chewing")
assert.strictEqual(M.parseIconUrl("/tmp/x/fcitx_mozc.svg"), "fcitx_mozc")
assert.strictEqual(M.parseIconUrl(""), "")
assert.strictEqual(M.parseIconUrl(null), "")

// Locale: only en, zh-TW, ja; zh_CN and anything else fall back to en.
assert.strictEqual(M.localeKey("zh_TW.UTF-8"), "zh-TW")
assert.strictEqual(M.localeKey("zh-Hant-TW"), "zh-TW")
assert.strictEqual(M.localeKey("zh_HK"), "zh-TW")
assert.strictEqual(M.localeKey("ja_JP.UTF-8"), "ja")
assert.strictEqual(M.localeKey("zh_CN.UTF-8"), "en")
assert.strictEqual(M.localeKey("de_DE"), "en")
assert.strictEqual(M.localeKey(""), "en")

// Known icons get macOS names in every locale.
assert.strictEqual(M.glyphFor("fcitx-chewing", "酷"), "ㄅ")
assert.strictEqual(M.titleFor("fcitx-chewing", "zh-TW", "Chewing"), "注音")
assert.strictEqual(M.titleFor("fcitx-chewing", "en", "Chewing"), "Zhuyin")
assert.strictEqual(M.glyphFor("fcitx_mozc_hiragana", ""), "あ")
assert.strictEqual(M.titleFor("fcitx_mozc_hiragana", "ja", "Hiragana"), "ひらがな")
assert.strictEqual(M.glyphFor("fcitx_mozc_katakana_full", ""), "ア")
assert.strictEqual(M.titleFor("fcitx_mozc_alpha_half", "zh-TW", "Half ASCII"), "英數")
assert.strictEqual(M.titleFor("fcitx_mozc", "en", "Mozc"), "Japanese")
assert.strictEqual(M.glyphFor("fcitx_mozc", ""), "あ")
assert.strictEqual(M.titleFor("fcitx_mozc_direct", "en", ""), "Direct")
assert.strictEqual(M.titleFor("fcitx_mozc_direct", "zh-TW", ""), "直接輸入")
assert.strictEqual(M.titleFor("fcitx_mozc_direct", "ja", ""), "直接入力")

// Keyboard layouts read ABC / A, whatever the icon theme calls them.
for (const icon of ["input-keyboard", "input-keyboard-symbolic", "fcitx-keyboard-us"]) {
  assert.ok(M.isKeyboard(icon), icon)
  assert.strictEqual(M.glyphFor(icon, "en"), "A")
  assert.strictEqual(M.titleFor(icon, "zh-TW", "Keyboard - English (US)"), "ABC")
}
assert.ok(!M.isKeyboard("fcitx-chewing"))

// Unknown engines: first char of fcitx5's label, uppercased when latin; title is fcitx5's text.
assert.strictEqual(M.glyphFor("fcitx-hangul", "한"), "한")
assert.strictEqual(M.glyphFor("fcitx-unikey", "vi"), "V")
assert.strictEqual(M.titleFor("fcitx-unikey", "zh-TW", "Unikey"), "Unikey")
// Unknown engine with no label and no text still gets something visible.
assert.strictEqual(M.glyphFor("fcitx-weird", ""), "?")
assert.strictEqual(M.titleFor("fcitx-weird", "en", ""), "fcitx-weird")

// Rows: an input method with cached modes becomes its visible modes.
const ims = [
  { icon: "input-keyboard", text: "Keyboard - English (US)", checked: false },
  { icon: "fcitx-chewing", text: "Chewing", checked: false },
  { icon: "fcitx_mozc", text: "Mozc", checked: true },
]
const cache = { fcitx_mozc: [
  { icon: "fcitx_mozc_direct", text: "Direct" },
  { icon: "fcitx_mozc_hiragana", text: "Hiragana" },
  { icon: "fcitx_mozc_katakana_full", text: "Full Katakana" },
  { icon: "fcitx_mozc_alpha_full", text: "Full ASCII" },
  { icon: "fcitx_mozc_alpha_half", text: "Half ASCII" },
  { icon: "fcitx_mozc_katakana_half", text: "Half Katakana" },
] }
const r = M.rows(ims, cache, M.DEFAULT_HIDDEN_MODES, "fcitx_mozc_katakana_full", "zh-TW")
assert.deepStrictEqual(r.map(x => x.title), ["ABC", "注音", "平假名", "片假名", "英數"])
assert.deepStrictEqual(r.map(x => x.checked), [false, false, false, true, false])
assert.deepStrictEqual(r[3], { im: "fcitx_mozc", mode: "fcitx_mozc_katakana_full", glyph: "ア", title: "片假名", checked: true })
assert.strictEqual(r[0].mode, "")

// Without cached modes the engine is one row, checked by the input method.
const r2 = M.rows(ims, {}, M.DEFAULT_HIDDEN_MODES, "", "en")
assert.deepStrictEqual(r2.map(x => x.title), ["ABC", "Zhuyin", "Japanese"])
assert.deepStrictEqual(r2.map(x => x.checked), [false, false, true])

// A cache where every mode is hidden falls back to the single engine row.
const r3 = M.rows(ims, { fcitx_mozc: [{ icon: "fcitx_mozc_direct", text: "Direct" }] }, M.DEFAULT_HIDDEN_MODES, "", "en")
assert.deepStrictEqual(r3.map(x => x.title), ["ABC", "Zhuyin", "Japanese"])

// Corrupt cached values fall back to the engine; bad mode entries are skipped.
assert.deepStrictEqual(M.rows(ims, { fcitx_mozc: "bad" }, [], "", "en").map(x => x.title), ["ABC", "Zhuyin", "Japanese"])
const malformed = M.rows(ims, { fcitx_mozc: [null, {}, { icon: 5 }, { icon: "fcitx_mozc_hiragana", text: "Hiragana" }] }, [], "fcitx_mozc_hiragana", "en")
assert.deepStrictEqual(malformed.slice(2), [{ im: "fcitx_mozc", mode: "fcitx_mozc_hiragana", glyph: "あ", title: "Hiragana", checked: true }])

// A mode row is not checked when its engine is not the current one.
const ims2 = ims.map(im => Object.assign({}, im, { checked: im.icon === "fcitx-chewing" }))
const r4 = M.rows(ims2, cache, M.DEFAULT_HIDDEN_MODES, "fcitx_mozc_hiragana", "en")
assert.deepStrictEqual(r4.filter(x => x.checked).map(x => x.title), ["Zhuyin"])

// Empty or missing inputs never throw.
assert.deepStrictEqual(M.rows([], {}, [], "", "en"), [])
assert.deepStrictEqual(M.rows(null, null, null, null, null), [])

// Strings exist in every locale with the same keys.
const keys = Object.keys(M.strings("en")).sort()
assert.deepStrictEqual(keys, ["addIm", "emoji", "enable", "notRunning", "onlyOne", "settings", "sniOff", "start", "switchFailed"])
for (const l of ["zh-TW", "ja", "xx"]) assert.deepStrictEqual(Object.keys(M.strings(l)).sort(), keys)
assert.strictEqual(M.strings("zh-TW").emoji, "表情與符號")

// QML gives a file: URL, not a C++ QUrl with toLocalFile(). Convert before launching.
assert.strictEqual(M.localFilePath("file:///tmp/input%20menu/o%27hara%23%25%20%C3%A9"), "/tmp/input menu/o'hara#% é")
assert.strictEqual(M.localFilePath("https://example.com/enable"), "")
// The launcher joins argv into a bash -c command: preserve spaces, quotes and metacharacters.
const path = "/tmp/input menu/o'hara;$HOME enable"
assert.strictEqual(require("child_process").execFileSync("bash", ["-c", "printf '%s' " + M.shellQuote(path)], { encoding: "utf8" }), path)

console.log("ok")
