## 基本command

### 3 インストール例（Java 11 と 21）
```
mise install java@corretto-11.0.24.8.1
mise install java@corretto-21.0.4.7.1
```

### フォルダ毎に切り替え(.tool-versionsの記載例)
```
builder@v133-18-162-33-vir:~/work$ ls -l ph3/.tool-versions
-rw-r--r-- 1 builder user 57  6月  7 02:52 ph3/.tool-versions
builder@v133-18-162-33-vir:~/work$ cat ph3/.tool-versions
java   corretto-11.0.24.8.1
gradle 8.5.0
node   20.18.2

builder@v133-18-162-33-vir:~/work$
```

### 一時切り替え
```
mise use -g       java@corretto-21.0.4.7.1
mise use java@corretto-11.0.24.8.1

cd ~/projects/legacyA
mise use          java@corretto-11     # .tool-versions を作成
```

### ■Gradle
```
mise ls-remote gradle@8.5.0
mise install gradle@8.5.0
```


### ■Node
```
mise install node@20.18.2
```

### ■Angular
```
npm view @angular/cli versions --json
npm install -D @angular/cli@18.2.19
npx ng version
```

## mise で Node.js と Angular CLI をプロジェクトごとに切り替える設計図

### 1. なぜ「Angular も mise で」と言わないのか

* **mise が直接扱うのは “ランタイム”**（Node.js, Java など）。
* Angular は Node.js 上で動く **npm パッケージ** なので、
  **Node.js さえ合っていれば `npm`／`npx` でバージョンを完全に固定**できます。
* よって

  1. **Node.js → mise でバージョン管理**
  2. **Angular CLI → `package.json` でプロジェクト依存に入れる**
     が最もシンプルで再現性が高い方法です。

---

### 2. Node.js を mise で管理する

```bash
# ❶ Node.js プラグインがまだなら追加
mise plugin add nodejs

# ❷ 必要な Node バージョンをインストール
mise install nodejs 18.20.3
mise install nodejs 20.15.1
```

#### プロジェクト A（Node 18）

`/path/to/projectA/.tool-versions`

```
nodejs 18.20.3
```

#### プロジェクト B（Node 20）

`/path/to/projectB/.tool-versions`

```
nodejs 20.15.1
```

ターミナルで

```bash
cd projectA && node -v   # → v18.20.3
cd ../projectB && node -v# → v20.15.1
```

と切り替わるのを確認します。

---

### 3. Angular CLI をプロジェクト依存に固定する

1. **プロジェクトごとに `@angular/cli` を devDependencies へ追加**

   ```bash
   # プロジェクト A は Angular 17 系を利用
   cd projectA
   npm init -y
   npm install -D @angular/cli@17

   # プロジェクト B は Angular 18 β（例）
   cd ../projectB
   npm init -y
   npm install -D @angular/cli@18.0.0-beta
   ```

2. **`npx ng …` でローカル版 CLI を呼び出す**

   ```bash
   cd projectA
   npx ng serve          # Angular 17 で開発サーバ
   cd ../projectB
   npx ng build --prod   # Angular 18 で本番ビルド
   ```

> `npx` は `node_modules/.bin` を優先するので
> グローバルに古い `ng` が入っていても問題ありません。

---

### 4. スクリプト化の例

```bash
# build-all.sh
set -euo pipefail

build() {
  local dir=$1
  echo "=== ${dir} をビルド ==="
  (
    cd "$dir"
    eval "$(mise env -s bash)"   # .tool-versions を反映
    npm ci                       # lockfile に従って依存解決
    npx ng build --configuration production
  )
}

build projectA   # Node 18 + Angular 17
build projectB   # Node 20 + Angular 18
```

```
#!/usr/bin/env bash
set -euo pipefail

build() {
  local dir="$1"
  echo "=== ${dir} をビルド ==="
  (
    cd "$dir"

    # .tool-versions を読み込んで JDK・Node を切り替え
    eval "$(mise env -s bash)"

    # バージョン確認
    java --version      # または java -version
    node -v             # Node の確認も入れると便利
    npx ng version      # Angular CLI のバージョン

    # 実ビルド（コメントアウトを外して使用）x
    # npm ci
    # npx ng build --configuration production
  )
}

build ph3   # ph3 の .tool-versions に従う
build ph4   # ph4 の .tool-versions に従う
```

* `eval "$(mise env …)"` で **サブシェルのみ** Node バージョンを適用。
* Angular CLI は `package-lock.json` / `pnpm-lock.yaml` などにより厳密固定される。

---

### 5. CI（GitHub Actions 例）

```yaml
strategy:
  matrix:
    project: [projectA, projectB]

steps:
  - uses: actions/checkout@v4

  - name: キャッシュ mise
    uses: actions/cache@v4
    with:
      path: |
        ~/.local/share/mise
        ~/.cache/mise
      key: mise-${{ runner.os }}-${{ hashFiles('**/.tool-versions') }}

  - name: Node & Angular build
    run: |
      cd ${{ matrix.project }}
      mise install          # .tool-versions が指す Node を取得
      eval "$(mise env -s bash)"
      npm ci
      npx ng build --configuration production
```

---

### 6. まとめ

1. **Node.js は mise でディレクトリ単位に切り替える**
   → `.tool-versions` に `nodejs <version>` を記述。
2. **Angular CLI は各プロジェクトの `devDependencies` へ固定**
   → `npm ci` と `npx ng …` で確実にローカル版が使われる。
3. CI では `mise env` または `mise exec` を使い、
   lockfile＋キャッシュで高速かつ再現性あるビルドが可能。

この方式なら、**Node と Angular を自由に組み合わせながらも設定ファイルで明示的に管理**でき、開発者・CI・本番環境すべてで同じ結果を再現できます。
