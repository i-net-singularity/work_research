承知した。RedHat 8.6 上に以下を統合的に構築・運用するためのガイドラインを作成する：

* Java 21 アプリ向けビルド環境（Gradle, Maven 最新安定版）
* Node.js + Angular アプリ向けビルド環境（LTS版 Node.js および最新版 Angular）
* Jenkins によるCI/CD運用（同一マシン上）
* 複数バージョンの Java / Node.js / Angular を共存・切替する手法（当初は手動export、将来的に自動切替も視野）

これらを RedHat 8.6 に対応する最新手法・公式推奨に沿って調査・整理し、長期運用を見据えた構成案とコマンド例を含めたドキュメントを作成する。


# Red Hat 8.6 開発ビルド基盤 構築・運用ガイド

## 前提と目的

本ガイドでは、Red Hat Enterprise Linux 8.6 上に**Java 21**（最新LTS版）および\*\*Node.js + Angular（現時点のLTS版 Node.jsと最新Angular）\*\*を対象とした開発ビルド基盤を構築し、JenkinsによるCI/CDを同一マシン上で運用する手順とベストプラクティスを解説します。複数バージョンのJavaやNode.js/Angularを必要に応じて切り替えてビルドできる環境を構築し、将来的には`sdkman`や`nvm`、Linuxの`alternatives`コマンド等の活用も視野に入れます。公式ドキュメントに基づいた安定運用手順を示し、実践的な手順書としてまとめます。

**構成要素:**

* **Java 21（OpenJDK 21）** + ビルドツール：Gradle（最新安定版）および Maven（最新安定版）
* **Node.js（LTS版） + Angular（最新バージョン）** + ビルドツール：Angular CLI 等
* **Jenkins（CI/CDサーバ）** – 上記のビルドを自動化する

以下、環境構築手順とポイントを順を追って説明します。

## Java（OpenJDK 21）環境の構築と複数バージョン対応

### OpenJDK 21 のインストール (RHEL公式手順)

Red Hat Enterprise Linuxでは、Red Hat提供のOpenJDKパッケージを利用できます。OpenJDK 21もRed Hatによるビルドが提供されており、サブスクリプション登録済みのシステムであれば標準のパッケージ管理でインストール可能です。以下にインストール手順を示します。

1. **パッケージインストール:** 管理者権限で次のコマンドを実行し、OpenJDK 21のJDKをインストールします（JREのみでなく開発に必要なコンパイラ含むJDKを推奨）。

   ```bash
   sudo yum install -y java-21-openjdk java-21-openjdk-devel
   ```

   上記コマンドによりOpenJDK 21がインストールされます。`-devel`パッケージを含めることで `javac` コンパイラも利用可能になります。インストール後、`java -version`や`javac -version`でバージョンを確認し、`openjdk version "21.*"` 等と表示されれば成功です。

2. **環境変数の設定:** OpenJDKをyumでインストールした場合、`/usr/bin/java`へのシンボリックリンク等が設定され、基本的なコマンドは即使用可能です。ただしビルドツールで`JAVA_HOME`が必要な場合もあるため、bash環境に`JAVA_HOME`を設定します（例：`/etc/profile.d/java.sh`に`export JAVA_HOME=/usr/lib/jvm/java-21-openjdk`を追記）。
   ※RHELのOpenJDKパッケージでは`/usr/lib/jvm/java-21-openjdk`といったディレクトリにインストールされ、`/usr/lib/jvm/java`のシンボリックリンクでデフォルトJDKを指すようになっています。

3. **動作確認:**

   ```bash
   java -version  
   ```

   と実行し、インストールされたJavaのバージョンが21であることを確認します。

### 複数バージョンのJavaインストールと切替

RHELでは**複数の主要バージョンのOpenJDKを共存インストール**することが可能です。例えば、Java 11やJava 17と併せてJava 21をインストールし、プロジェクトに応じて使い分けることができます。標準パッケージを利用する場合、以下のような手順で複数バージョン対応を行います。

* **追加バージョンのインストール:** 例としてJava 17を追加したい場合、`sudo yum install java-17-openjdk java-17-openjdk-devel`を実行します（OpenJDK 17u もRed Hatより提供されています）。同様にJava 11が必要なら`java-11-openjdk`をインストールします。

* **バージョンの切替:** システム全体で使用するJavaのバージョン切替には、RHELの**代替操作 (`update-alternatives`)** を利用します。`update-alternatives --config java`コマンドを実行すると、インストール済みのJavaコマンドの候補一覧が表示され、システム既定で使用するバージョンを選択できます。例えばJava 21を既定にしたい場合、上記コマンド実行後のプロンプトでJava 21 (OpenJDK 21) のエントリを選択します。

  ```bash
  sudo update-alternatives --config java  
  # 対応する番号を入力してエンター  
  ```

  > 🛈 *参考:* Red Hat公式ドキュメントでも「複数のOpenJDKをインストールし`update-alternatives --config 'java'`で切り替え可能」と明記されています。

* **アプリケーション単位での切替:** システムグローバルでなく、特定のビルドジョブやセッション内で一時的にJavaバージョンを切り替えたい場合は、環境変数`JAVA_HOME`と`PATH`を切り替える方法が簡便です。例えばJDK 11を`/opt/jdk-11`に配置している場合、そのビルド前に以下を実行します。

  ```bash
  export JAVA_HOME=/opt/jdk-11  
  export PATH="$JAVA_HOME/bin:$PATH"  
  ```

  これにより、カレントシェル内では`java`コマンドがJDK 11のものになります（別途元に戻すにはJava 21のパスを再設定）。

* **SDKMANの活用（将来的な選択肢）:** 複数のJDKをユーザ単位で手軽に管理する方法として、**SDKMAN!** の利用があります。SDKMANはUNIX系OS上で複数バージョンのSDK（Javaを含む）を並行管理できるツールであり、例えば`sdk install java 21.0.**`等のコマンドで特定バージョンのインストール・切替が可能です。SDKMAN自身のインストールが必要ですが、将来的に開発環境で頻繁にJavaバージョンを切り替える場合には有力な選択肢です。

### （参考）OpenJDKアーカイブからの手動インストール

OpenJDKをyumでなく手動でインストールすることも可能です。例えばRed Hat提供のOpenJDKアーカイブをダウンロードし、システムに展開して使う方法があります。手順の概要:

1. Red Hat カスタマーポータルからOpenJDK 21のアーカイブ（JDK版）を入手。
2. 適当なディレクトリ（例：`/opt/jdk`やホームディレクトリ直下）に展開。
3. 展開先を分かりやすくするため、シンボリックリンクで汎用パスを作成（例：`ln -s /opt/jdk/<展開フォルダ名> /opt/jdk/java-21`）。
4. 環境変数`JAVA_HOME`にそのパスを設定し、`PATH`に`$JAVA_HOME/bin`を追加。これでカレントユーザでJava 21が利用可能になります（システム全体に反映するには`/etc/profile.d`にexportを記述）。

> ℹ️ *補足:* アーカイブから手動インストールしたJavaはそのユーザの環境でのみ有効となります。システムサービス（例えばJenkins）はその環境設定を自動では読み込まないため、Jenkinsで使用するには後述のようにジョブ内で環境変数を設定するか、Jenkinsのツール設定に登録する必要があります。

## Node.js（LTS）およびAngular環境の構築と複数バージョン対応

### Node.js (現行LTS版) のインストール

Red Hat Enterprise Linux 8系では、**Application Stream (AppStream)** としてNode.jsの複数バージョンがモジュール化されています。2025年現在のLTSであるNode.js 20もRHEL8上で利用可能です。公式には以下の手順でインストールします。

1. **モジュールストリームの有効化:** Node.js 20を使用するため、まずNode.js 20モジュールを有効化します。

   ```bash
   sudo dnf module enable nodejs:20
   ```

   上記により、Node.js 20のパッケージストリームが有効になります（`dnf module list nodejs`で利用可能なバージョン一覧を確認可能）。

2. **Node.jsパッケージのインストール:**

   ```bash
   sudo dnf install -y nodejs
   ```

   これにより、Node.js 20（有効化したストリームの最新版）と、付随するnpm等がインストールされます。`node -v`コマンドでバージョンが`v20.x`であることを確認してください。

   > 🛈 *参考:* RHEL公式ブログでも、Node.js LTS版を利用する場合はモジュールを有効化後に`dnf install nodejs`する手順が推奨されています。

3. **npm/npm scriptsの使用準備:** npmはNode.jsと共にインストールされます。`npm -v`でバージョン確認できます。今後Angular CLI等のパッケージインストールに使用します。

4. **Node.jsの動作確認:**

   ```bash
   node -v && npm -v  
   ```

   を実行し、それぞれNode.jsとnpmのバージョンが表示されれば成功です。

### Angular CLI のインストール

AngularアプリのビルドにはAngular CLIが必要です。CLI自体はnpm経由で提供されているため、グローバルインストールしておくと便利です。以下のコマンドで最新のAngular CLIをシステムにインストールします。

```bash
sudo npm install -g @angular/cli
```

上記によりコマンド`ng`が使用可能になります。`ng version`コマンドでAngular CLIおよびAngularフレームワークのバージョン情報が確認できます。

> ℹ️ *補足:* 複数のAngularバージョンプロジェクトをビルドする場合、**Angular CLIは基本的に後方互換**を持つため最新CLIで旧バージョンプロジェクトもビルド可能ですが、必要に応じてプロジェクト毎にローカルインストールされたCLI（`node_modules`内のCLI）を利用することもできます。その場合、Jenkinsジョブ内で`npx ng ...`を使うか、`npm ci`でプロジェクト依存関係をインストールしてから`npm run build`等のプロジェクト定義のビルドスクリプトを実行すると良いでしょう。

### Node.jsの複数バージョン切替

異なるプロジェクトで要求Node.jsバージョンが異なる場合に備え、Node.jsも複数バージョンを切り替えられるようにしておくと便利です。RHEL8のモジュール機能は一度に一つのバージョンしか有効化できないため、並行利用には工夫が必要です。以下、代表的な方法を挙げます。

* **手動切替（環境変数パス切替）:** 例えばNode.js 18系も必要な場合、NodeSource等からNode 18のバイナリを取得して`/opt/nodejs18`に配置しておき、ビルド時に一時的に`PATH`を切り替える方法があります。具体的には、ジョブ実行前に `export PATH="/opt/nodejs18/bin:$PATH"` のように環境変数を設定し、そのシェル内でビルドを行います。こうすることで、そのビルドに限り`node`コマンドが別バージョンに切り替わります。

* **Node Version Manager (nvm) の利用:** 開発環境で広く使われる**nvm**を導入すると、ユーザ単位で複数のNode.jsを簡単にインストール・切替できます。Jenkinsサーバ上でもJenkinsユーザにnvmをインストールし（nvm自体はスクリプトで容易にセットアップ可能）、ビルドジョブ内で例えば `nvm use 18` 等と実行することでバージョン切替ができます。nvmはユーザのシェル環境で動くため、Jenkinsではジョブのビルドスクリプト中に`source ~/.nvm/nvm.sh`を呼び出してnvmコマンドを有効化する必要があります。プラグインに比べ手動設定が必要ですが、非常に柔軟でおすすめの方法です。

* **JenkinsのNodeJSプラグイン利用:** JenkinsにはNode.jsを管理する公式プラグイン（NodeJS Plugin）があり、これを使うと**複数のNode.jsインストールをJenkins側で保持し、ジョブ毎に選択**できます。プラグイン設定画面（Jenkinsの「Global Tool Configuration」）で必要なNode.jsバージョン（例えば14、16、18など）をそれぞれ登録し、「自動インストール」を有効にすると、ジョブ実行時に指定バージョンのNode.jsを自動でダウンロード・使用してくれます。さらに、このプラグインではグローバルnpmパッケージの自動インストールも設定でき、Angular CLIなどをビルドエージェントに展開することも可能です。例えば「NodeJSのツール設定でAngular CLIをグローバルNPMパッケージとして指定→ジョブでそのNode.jsプロファイルを使用」とすれば、`ng`コマンドも自動的にパスに通ります。

> 🛈 *参考情報:* NodeJSプラグインを使用すると、Jenkins設定から複数のNode.jsプロファイルを登録でき、ジョブで簡単に切替可能です。一方で「サーバに直接nvmを入れてシェルで`nvm use`する方法はプラグイン不要で柔軟」と推奨する意見もあります。運用方針に応じて適切な方法を選択してください。

## GradleおよびMavenのインストールと管理

### Maven（ビルドツール）のインストール

MavenはJavaプロジェクトのビルド管理ツールです。RHEL8では**デフォルトでMaven 3.5**程度の古いバージョンが利用可能ですが、最新版を使うには手動インストールが必要です。ここでは安定運用の観点から2通りの方法を示します。

* **方法A: OS標準パッケージを利用（簡易）** – まず動かすことを優先する場合、RHELのリポジトリから提供されるMavenをインストールします。

  ```bash
  sudo dnf install -y maven
  ```

  これでMaven本体と依存パッケージがインストールされます。インストール後、`mvn -v`でMavenのバージョンが表示されれば成功です（RHEL8のAppStreamに含まれるMavenは執筆時点では3.5系です）。
  *メリット:* パッケージ管理されるため更新も容易。 *デメリット:* バージョンが古めの場合がある。

* **方法B: 手動インストール（最新版を利用）** – 最新のMaven 3.8+ を利用したい場合は、Apache公式サイトからバイナリをダウンロードし配置します。手順例:

  1. Apache Maven公式から最新のバイナリ配布（`apache-maven-<version>-bin.tar.gz`）を取得し、サーバにアップロードします。
  2. `/opt`ディレクトリなどに展開し、フォルダ名をわかりやすくリネームします（例: 展開後のフォルダ`apache-maven-3.9.x`を`/opt/maven`にリネーム）。
  3. 環境変数を設定します。例えば`/etc/profile.d/maven.sh`を作成し、次を記述:

     ```bash
     export M2_HOME=/opt/maven  
     export PATH="$M2_HOME/bin:$PATH"
     ```

     併せて`JAVA_HOME`も必要に応じて設定。これでシステム全体で`mvn`コマンドが利用可能になります。
  4. `source /etc/profile.d/maven.sh` または新しいシェルを開いて、`mvn -v`でバージョンを確認します。Maven自身のバージョンとJavaのバージョン情報が表示されれば成功です（Mavenホームが上記で設定したパスになっていることも確認できます）。

  *メリット:* 最新版のMavenを使用可能。 *デメリット:* アップデートは手動で行う必要があります。

* **複数バージョンのMaven切替:** MavenもGradleも、複数バージョンを共存させて必要に応じ切替可能です。手動インストールする場合、例えば`/opt/maven3.6`と`/opt/maven3.8`のように別フォルダに配置し、ビルド時に`M2_HOME`や`PATH`を付け替える方法が使えます（Javaの切替と同様の考え方です）。また将来的にはSDKMANでMavenを管理することもできます（`sdk install maven 3.8.7`など）。

### Gradle（ビルドツール）のインストール

Gradleは最新技術スタックでよく使われるビルド自動化ツールです。RHELの標準リポジトリにはGradleは含まれないため、**公式サイトからの手動インストール**または**SDKMANの利用**が一般的です。

* **Gradle公式サイトからインストール:** Gradle公式が案内する手順に従います。

  1. Gradle公式サイト（またはReleaseページ）から最新安定版のバイナリZipをダウンロードします。執筆時点ではGradle 8系が最新です。
  2. ダウンロードしたZipを展開します。例として`/opt/gradle`ディレクトリを作成し、そこに展開します。

     ```bash
     sudo mkdir /opt/gradle  
     sudo unzip -d /opt/gradle gradle-<version>-bin.zip  
     ls /opt/gradle/gradle-<version>   # 展開されたディレクトリの内容確認
     ```
  3. 環境変数`PATH`にGradleのbinディレクトリを追加します。例えば`/etc/profile.d/gradle.sh`を作成し、次を記載:

     ```bash
     export PATH=$PATH:/opt/gradle/gradle-<version>/bin
     ```

     これでシステム全体で`gradle`コマンドが使えるようになります（ユーザ環境のみで良い場合は各ユーザの`~/.bashrc`に書き込んでも構いません）。
  4. `gradle -v`コマンドでインストール成功を確認します。「Gradle <version>」と共にJVM情報等が表示されればセットアップ完了です。

* **SDKMANでGradle管理（オプション）:** GradleはSDKMANでの管理に公式対応しており、SDKMANが導入済みであれば `sdk install gradle <version>` のワンライナーでインストール・切替ができます。SDKMANを使うと複数バージョンのGradleを切替えるのもコマンド一つで済むため、プロジェクトごとにGradleバージョンが異なる場合に有用です。
  ※SDKMAN経由の場合、Gradle公式が配布する純粋なバイナリが使われるため安心です（一部LinuxディストリのシステムパッケージはGradleを改変している可能性がある旨が公式にも記載されています）。

* **Gradle Wrapperの活用:** なおGradleプロジェクトでは`gradlew`（Gradle Wrapper）が同梱されている場合があります。Wrapperを使えばシステムにGradleをインストールしていなくてもプロジェクトごとに指定バージョンのGradleを自動ダウンロードしてビルドできます。CI環境ではWrapper利用が一般的ですので、基本的にはGradle本体を都度インストールせずとも各プロジェクト内のWrapperを使う運用でも問題ありません。

## Jenkinsのインストールと設定

### Jenkinsのインストール（RHEL8）

JenkinsはJavaで動作するCIサーバです。Red Hat系OS向けに公式のYUMリポジトリが提供されていますので、それを利用してインストールします。手順:

1. **リポジトリ登録:** Jenkins公式のstableリポジトリ定義を取得し、yumリポジトリに登録します。

   ```bash
   sudo wget -O /etc/yum.repos.d/jenkins.repo \
       https://pkg.jenkins.io/redhat-stable/jenkins.repo  
   sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
   ```

   上記でJenkins用のリポジトリとGPGキーを追加します。

2. **依存関係のインストール:** JenkinsはJavaで動くため、OpenJDKが必要です。前述のJavaセットアップ済みであれば改めて入れる必要はありませんが、念のため以下を実行してフォント関連など必要パッケージも含めインストールします。

   ```bash
   sudo dnf install -y fontconfig java-21-openjdk
   ```

   （Javaを別途インストール済みの場合も、`fontconfig`はJenkins表示用に必要です。）

3. **Jenkins本体のインストール:**

   ```bash
   sudo dnf install -y jenkins
   ```

   これによりJenkins最新版（LTS版）がインストールされます。インストール後、自動的に`jenkins`というシステムユーザが作成され、Jenkinsサービスが登録されます。

4. **サービス起動と自動起動設定:**

   ```bash
   sudo systemctl enable jenkins  # ブート時自動起動設定:contentReference[oaicite:59]{index=59}  
   sudo systemctl start jenkins   # Jenkinsサービスの起動:contentReference[oaicite:60]{index=60}
   ```

   起動後、`sudo systemctl status jenkins`でステータスを確認し、`active (running)`となっていればOKです。

5. **ファイアウォール設定（必要に応じて）:** サーバにfirewalld等が有効な場合、Jenkinsデフォルトポート8080を開放します。例えば以下のコマンドで許可:

   ```bash
   sudo firewall-cmd --permanent --zone=public --add-port=8080/tcp  
   sudo firewall-cmd --reload
   ```

   （詳細なfirewalldサービス登録手順はを参照。）

6. **初期セットアップ:** ブラウザで `http://<サーバIPまたはホスト名>:8080` にアクセスします。初回起動時は「Unlock Jenkins」画面が表示され、管理者パスワードの入力を求められます。サーバ上で以下を実行し、初期パスワードを確認して入力してください。

   ```bash
   sudo cat /var/lib/jenkins/secrets/initialAdminPassword
   ```

   その後、プラグインの自動インストールや初期ユーザ作成を行えばJenkinsの利用を開始できます。

> 🛈 *参考:* Jenkinsの公式パッケージをインストールすると、Jenkinsはシステム起動時にデーモンとして動作し、**専用ユーザ「jenkins」でプロセスが実行**されます。このユーザはデフォルトでは管理者権限を持たず、/var/lib/jenkins以下がホームディレクトリとなります。Jenkinsを運用する際は、このユーザ権限で不足がないよう、必要ファイルのパーミッションを調整してください（例えば、前述の手動インストールしたツールを`/opt`に配置した場合はjenkinsユーザが実行できるよう実行権限を付与）。セキュリティのため、Jenkinsサービスをrootで直接実行しないことが望ましいです。

### Jenkins上でのジョブ構成とビルド環境設定

Jenkinsを用いてJavaアプリやAngularアプリをビルドする際の設定ポイントを説明します。特に**ジョブ毎に異なるJavaやNode.jsのバージョンを使い分ける**ための方法に焦点を当てます。

* **Java向けジョブの設定:** Jenkinsでは**グローバルツール設定**で複数のJDKを登録し、ジョブ単位で利用JDKを指定することが可能です。Jenkins管理画面の「Global Tool Configuration」でJDKパス（例：`/usr/lib/jvm/java-11-openjdk`など）を名前付きで登録しておき、フリースタイルジョブなら「ビルド環境で特定のJDKを使用」を選択、PipelineジョブならDeclarative Pipeline内で `tools { jdk '<登録名>' }` を指定することで、そのジョブ内でPATHが切り替わります。例えばJDK 8と11を登録済みの場合、Pipelineスクリプト中でステージ毎に以下のように指定できます:

  ```groovy
  pipeline {
    agent any 
    stages {
      stage('Build with Java 8') {
        tools { jdk 'JDK8' }
        steps {
          sh 'java -version'  // Java 8 が使われる:contentReference[oaicite:70]{index=70}
          sh './gradlew build'
        }
      }
      stage('Build with Java 11') {
        tools { jdk 'JDK11' }
        steps {
          sh 'java -version'  // Java 11 が使われる:contentReference[oaicite:71]{index=71}
          sh 'mvn clean package'
        }
      }
    }
  }
  ```

  あるいはスクリプト内で `withEnv(["JAVA_HOME=${tool 'JDK11'}", "PATH=${tool 'JDK11'}/bin:${env.PATH}"]) { ... }` のようにして切り替えることもできます。いずれにせよ、Jenkins標準機能でジョブ実行時に自動で指定JDKをPATHに入れることが可能です。

* **Node.js/Angular向けジョブの設定:** Node.jsの場合、上述の**NodeJSプラグイン**を利用することで、ジョブのビルド前に自動で指定バージョンのNode.jsをセットアップしPATHを切り替えることができます。フリースタイルジョブではビルド環境で「Provide Node & npm bin/Folder to PATH」（プラグイン導入時）を使い、対象Node.jsインストールを選択します。Pipelineジョブでは、`nodejs()`パイプラインステップやツール設定を使ってPATHに含めることが可能です。
  例：

  ```groovy
  pipeline {
    agent any 
    tools { nodejs 'Node16' }  // あらかじめ登録したNode.js 16を使用
    stages {
      stage('Build Angular') {
        steps {
          sh 'node -v && npm -v'  // 指定したNode.jsのバージョン確認
          sh 'npm ci && npm run build'
        }
      }
    }
  }
  ```

  上記のように設定すれば、ジョブ実行時にNodeJSプラグインがNode.js 16を自動インストール（未インストールなら）し、PATHに設定した上でビルドを行います。加えて、このプラグイン設定でAngular CLIをグローバルインストールするオプションを有効にしておけば、例えば`ng build`も直接実行可能です。

  一方、NodeJSプラグインを使わない場合は**シェルスクリプトでnvmを使うアプローチ**も取れます。ビルドジョブ内のシェル実行で `source ~/.nvm/nvm.sh && nvm use 18` のように切り替え、その後`npm run build`する方法です。この場合、ジョブを実行するJenkinsユーザ（`jenkins`）のホームディレクトリにnvmと必要なNodeバージョンをあらかじめセットアップしておく必要があります。

* **ジョブ実行ユーザと権限:** Jenkinsジョブは前述の通り通常`jenkins`ユーザ権限で実行されます。そのため、ジョブ内で実行するビルドツールやファイル操作は基本的にroot権限なしで可能な範囲に留める必要があります。例えば、GradleやMavenビルドで生成されるファイルの所有者はjenkinsユーザとなり、ワークスペースも/var/lib/jenkins内に作られます。システムにインストールしたツールへのPATH設定を行う際、`/usr/bin`配下のコマンドであれば問題ありませんが、`/opt`に配置したツールの場合そのディレクトリや実行ファイルに適切な実行権限(少なくともOthersに対する読み取り・実行権限)を付けておく必要があります。

  加えて、Jenkinsサーバ管理者は必要に応じてジョブ毎の権限管理（例えばジョブの実行権限を特定ユーザに限定する等）を構成しますが、これにはJenkinsの**Role-Based Strategy**プラグイン等の利用が必要です。ここでは詳細は割愛しますが、少なくとも初期段階ではJenkins管理者ユーザでのみジョブを作成・実行できるようにしておき、権限誤設定によるジョブ改ざんを防ぎましょう。

以上が、Red Hat 8.6上でJava/Node.jsの開発ビルド基盤を構築し、複数言語・複数バージョンに対応したCI/CD環境を整備するための手順とポイントです。公式ドキュメントに基づき安定性と将来の拡張性に配慮した構成としました。各種ツールのアップデート情報にも留意しつつ、運用を進めてください。

**参考資料:** OpenJDK、Node.js、Jenkins、他 (本文中に示したとおり)。
