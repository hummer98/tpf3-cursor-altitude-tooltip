# Cursor Altitude Tooltip (Transport Fever 3)

[日本語は下にあります](#日本語)

Hold the **Surface Snapping** key (Alt by default) on the plain map view and
the cursor tooltip shows the altitude of the terrain under the mouse, instead
of the usual name tooltip. Release the key and the usual tooltip comes back.

## Features

- Altitude of the terrain under the mouse cursor, one decimal.
- Follows the game's unit setting (metres / feet).
- Follows your key binding: whatever key you bind to "Surface Snapping" in
  the game's key bindings is the key that shows the altitude.
- The label is translated into all 13 languages of the game.

## Where it shows, and where it doesn't

- Shows on the plain map view: no build tool, no layer, no window with its
  own cursor open. Pinned windows alone don't count.
- Not shown while a tool or a layer is active, or while a station, vehicle,
  line, industry or town window is open (they bring their own cursor and
  tooltip).
- Over buildings and water, the ground below is measured, not the roof or
  the water surface.

## Compatibility

- GUI only: it changes no save data, so it can be added to or removed from a
  running save at any time.
- Works alongside other mods that wrap the same map-view function (both
  wraps chain).

## Install

- mod.io: _link to be added_ (subscribe in the game's mod manager).
- Manually: the game loads a local mod only from a folder named exactly
  `hummer_cursor_altitude_tooltip_1` inside
  `<Steam>/userdata/<your id>/3493540/local/mods/`.
  - From the release zip: create that folder and extract the zip **into**
    it (the zip has no top folder of its own).
  - From GitHub: `git clone https://github.com/hummer98/tpf3-cursor-altitude-tooltip.git hummer_cursor_altitude_tooltip_1`
    inside `local/mods/` (a different folder name will not load).
  - Then enable the mod in the game.

## Development

The code is plain Lua (`content/gui/`):

| File | Role |
|---|---|
| `cat_core.lua` | Pure helpers (text, units), no engine access |
| `cat_map.lua` | Wraps the plain map view's action and swaps its tooltip |
| `cat_install.res.lua` / `.script.lua` | Hook run at UI start-up |

Tests run offline with LuaJIT and stub the game API:

```sh
luajit tests/run.lua
```

`python3 tools/package.py` runs the tests and builds
`dist/hummer_cursor_altitude_tooltip_1.zip` with only the files the game
needs (no `.git`, tests or tools). The mod.io page text for every language is
in [docs/modio_description.md](docs/modio_description.md).

## License

[MIT](LICENSE) © 2026 hummer

---

## 日本語

# カーソル位置の標高表示（Transport Fever 3）

通常の地図画面で **「地表スナップ」キー**（初期設定は Alt）を押している間、
マウスのヒントに、通常の名前表示の代わりにカーソル位置の地形の標高を表示します。
キーを離すと通常のヒントに戻ります。

### 機能

- マウスカーソル下の地形の標高を小数1桁で表示します。
- ゲームの単位設定（メートル／フィート）に従います。
- キー割り当てに従います。ゲームのキー設定で「地表スナップ」に割り当てたキーで表示されます。
- 表示ラベルはゲームの全13言語に対応しています。

### 表示される場面・されない場面

- 表示される：ツールもレイヤーも使っておらず、独自のカーソルを持つウィンドウも開いていない通常の地図画面。ピン留めしたウィンドウだけなら表示されます。
- 表示されない：ツールやレイヤーを使用中のとき、駅・車両・路線・産業・町のウィンドウを開いているとき（それぞれ独自のカーソルとヒントを持つため）。
- 建物や水面の上では、屋根や水面ではなく、その下の地面の高さを表示します。

### 互換性

- GUI だけの Mod で、セーブデータを変更しません。プレイ中のセーブにいつでも追加・削除できます。
- 同じ地図画面の関数を差し替える他の Mod とも併用できます（差し替えが連鎖します）。

### 導入

- mod.io：_リンクは公開後に追記_（ゲーム内の Mod 管理から購読）
- 手動：ゲームは `<Steam>/userdata/<ID>/3493540/local/mods/` の中の、
  名前がちょうど `hummer_cursor_altitude_tooltip_1` のフォルダからだけ読み込みます。
  - リリースの zip から：そのフォルダを作り、その**中に** zip を展開します（zip には外側のフォルダがありません）。
  - GitHub から：`local/mods/` の中で `git clone https://github.com/hummer98/tpf3-cursor-altitude-tooltip.git hummer_cursor_altitude_tooltip_1` とします（別のフォルダ名では読み込まれません）。
  - そのあとゲーム内で有効にします。

### ライセンス

[MIT](LICENSE) © 2026 hummer
