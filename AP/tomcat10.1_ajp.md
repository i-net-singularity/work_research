# Apache HTTP Server 2.4.37 と Tomcat 10.1 の AJP（mod\_proxy\_ajp）連携構成ガイド

## 概略

* この構成のメリット・デメリット
* 運用上の注意点（特にセキュリティと接続安定性）
* Apache 側（mod\_proxy\_ajp）と Tomcat 側（server.xml）の設定サンプル

下記サイトを参考に、Web⇔APの分離構成に即した実践的なガイド。

* Tomcat公式サイト（[https://tomcat.apache.org/）](https://tomcat.apache.org/）および)
* Apache HTTP Server 公式ドキュメント

## 1. 構成のメリット・デメリット

### メリット

* **機能分離と性能向上:** Apache HTTP Serverをフロントに配置することで、静的コンテンツの配信やSSL処理をApache側で担わせ、Tomcatは動的コンテンツ（Javaアプリケーション）に専念できます。AJPはバイナリプロトコルであり、ApacheとTomcat間の通信を効率化し、TCP接続を維持することでソケット作成のオーバーヘッドを削減します。結果として全体のパフォーマンス向上とリソース効率化が期待できます。
* **ホスト統合とシンプルな設定:** mod\_proxy\_ajp はリバースプロキシとして動作する際、リクエスト元のHostヘッダ情報をそのままTomcatに渡します。そのため、通常は **ProxyPassReverse** のようなヘッダ書き換え設定を省略でき、構成が簡素になります。また、Tomcat側では **Engine** 要素の **jvmRoute** 属性を利用してセッションを維持するロードバランシング構成が可能であり、高可用性構成に容易に拡張できます。
* **保守性と拡張性:** ApacheとTomcatを分離することで、各コンポーネントを独立して再起動・アップデートできます。例えば、Apacheの設定変更やモジュール更新の際にTomcatを停止する必要がなく、逆も同様です。このモジュール構成はApache HTTP Server組み込みの拡張（mod\_proxy\_ajp）を利用しており、追加の外部コネクタ（例: mod\_jk）をインストールする必要がないため環境管理が容易です。

### デメリット

* **セキュリティ上のリスク:** AJPプロトコルは高い権限でTomcat内部と連携するため、設定を誤ると重大なリスクを招きます。AJPコネクタを公開ネットワークにさらすことは非常に危険であり、過去にはAJP経由での情報漏洩脆弱性も報告されています。このためTomcatではデフォルトで AJPコネクタに **secretRequired="true"**（共有シークレット必須）が設定されています。しかし、Apache 2.4.37 は **ProxyPass** の `secret` パラメータに対応していないため（2.4.42以降でサポート）、シークレットを利用する場合はApacheのアップグレードが必要になります。一方、シークレットを使わず **secretRequired="false"** とする場合は、AJPコネクタを内部ネットワークだけで聴取させるなど慎重な対策が不可欠です。
* **複雑性と可用性:** この構成ではApacheとTomcatという二つのサーバを管理する必要があり、純粋なTomcat単体運用に比べて複雑になります。それぞれに障害が発生した場合、アプリケーションは利用不可となるため、両方の高可用性を確保する設計が必要です。またApacheを経由する分、多少のオーバーヘッドが発生します。しかしこれはAJPの効率的な設計によって最小限に抑えられています。
* **保守の手間:** 二つの異なるソフトウェアスタック（Apache設定とTomcat設定）を管理・チューニングする必要があります。問題発生時にはApacheとTomcat両方のログ解析や設定見直しが必要となり、単一サーバ構成よりもトラブルシューティングが煩雑です。また、ApacheとTomcat間のバージョンや設定の組み合わせ（例: シークレットのサポート可否）にも注意が必要です。

## 2. 想定すべき注意点

* **AJPコネクタのセキュリティ:** TomcatのAJPコネクタ利用時には特に慎重なセキュリティ対策が必要です。Tomcat公式も、AJP利用時は **address**, **secret**, **secretRequired**, **allowedRequestAttributesPattern** といった属性設定に注意を払うよう警告しています。AJPはTomcat内部構造への直接操作を許す高度に信頼されたプロトコルであるため、信頼できるクライアント（フロントエンドのApache）からのみに接続を限定し、その他のアクセスは遮断します。ファイアウォール等でAJPポート（通常8009）へのアクセスをApacheサーバからのみに制限し、Tomcatの **<Connector>** 要素では **address** 属性を用いて受け入れるIPアドレスを内部ネットワークに限定することが推奨されます。
* **AJPシークレットの利用:** 前述の通り、Tomcat 10.1ではデフォルトでAJPコネクタにシークレットの設定が求められます。本番環境ではApacheとTomcat間で共通のシークレット文字列を設定し、認証された接続のみを許可する構成が推奨されます。Apache HTTP Server 2.4.42以降では、**ProxyPass** のURLに `secret=...` パラメータを指定することでTomcatにシークレットを渡せます。Apache 2.4.37環境でシークレットを使用する場合、Apacheの更改またはmod\_proxy\_ajpのバックポートが必要です。どうしてもシークレットを使用しない場合（**secretRequired="false"**）、当該Tomcat AJPポートを厳密に内部だけに限定し、未認可のアクセスを遮断するよう十分注意してください。
* **信頼できるネットワークの確保:** ApacheとTomcat間の通信はデフォルトでは暗号化されません。従って両者は同一の信頼できるネットワーク内に配置し、第三者に盗聴・改竄されないようにします。必要に応じてVPNやIPsec等で通信経路を保護することも検討してください。また、Apache側ではグローバルなプロキシ機能を無効化（`ProxyRequests Off`がデフォルト）し、意図しないオープンプロキシ化を防止します。
* **mod\_proxy\_ajpの特性:** mod\_proxy\_ajpはHTTPプロキシと似た構文で設定できますが、いくつか特有の挙動があります。例えば **Hostヘッダ** はデフォルトでクライアントがリクエストした値がそのままTomcatに渡されるため、通常**ProxyPreserveHost On**を明示しなくてもTomcat側でオリジナルのホスト名が認識されます。また、環境変数をバックエンドに引き継ぐ場合はApache側で名前を **`AJP_`** で始まる変数として設定すると、その **`AJP_`** を除いた名前でTomcatに渡されます（例：`SetEnv AJP_MYVAR "value"`とするとTomcat側では `request.getAttribute("MYVAR")` で取得可能）。さらに、バックエンドへの接続が長時間アイドル状態で切断されてしまった場合に備え、**ProxyPass** に `ping=1` オプションを付与してApacheがリクエスト送信前にAJPコネクションをテストすることも可能です。
* **リダイレクトとパスの注意:** 通常、AJP経由では自己参照URLのホスト部分は書き換え不要ですが、Apache側のパスとTomcat側のコンテキストパスが異なる場合には、`Location`ヘッダ書き換えのため**ProxyPassReverse**の設定が必要です。可能であればフロント（Apache）とバックエンド（Tomcat）で同一のパス構造をとることで、設定の簡略化と誤動作の防止につながります。
* **認証情報の取り扱い:** Apache側でBasic認証やクライアント証明書認証を実施し、その結果をTomcatに引き継ぎたい場合、TomcatのAJP Connectorで **tomcatAuthentication="false"** を指定します。これによりApacheが設定したユーザ名（環境変数 `REMOTE_USER`）がAJPのリクエスト属性としてTomcatに伝達され、Tomcat側で再度認証を行わずにそのユーザ名を利用できます。また必要に応じて **tomcatAuthorization** を`true`に設定すれば、Apache側で認証されたユーザをTomcat側でも認証済みとみなし、適切にロールを割り当ててアクセス制御を行えます（デフォルトは`false`）。デフォルトでは **tomcatAuthentication="true"** であり、Tomcatが独立して認証を行う点に留意してください。

## 3. 実際の構成例

### Apache HTTP Server 側の設定

Apache側では、`mod_proxy` および `mod_proxy_ajp` モジュールを有効にした上で、仮想ホスト設定内に以下のようなプロキシ設定を記述します。AJP用のプロキシURLは `ajp://` スキームで記述し、必要に応じてシークレット文字列（**secret** パラメータ）等を付加します（Apache 2.4.42以降の場合）。

```apacheconf
# Apache HTTP Server の設定例（/etc/httpd/conf.d/proxy-ajp.conf 等）
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_ajp_module modules/mod_proxy_ajp.so

<VirtualHost *:80>
    ServerName example.com
    ProxyPass        "/"  "ajp://tomcat-server.example.com:8009/" retry=0
    ProxyPassReverse "/"  "http://example.com/"
    # シークレットを使用する場合（Apache 2.4.42+ の構文）
    # ProxyPass        "/"  "ajp://tomcat-server.example.com:8009/" secret=MY_AJP_SECRET
    ProxyPreserveHost On
</VirtualHost>
```

**設定解説:**

* **ProxyPass／ProxyPassReverse:** クライアントからの`/`配下の要求をバックエンドのTomcat（例: `tomcat-server.example.com:8009`）に転送します。フロント側のパスとバックエンドのコンテキストパスが一致している場合、**ProxyPassReverse** の指定は通常不要ですが、ここでは明示しています。`retry=0` はバックエンド障害時にリクエストを即座に失敗させる設定例です（必要に応じて調整可能です）。
* **secret パラメータ:** ApacheがTomcatに接続する際の共有シークレットを指定するオプションです（Apache 2.4.42以降でサポート）。`secret=MY_AJP_SECRET` のように記述し、Tomcat側の **secret** 属性と値を一致させます。Apache 2.4.37ではこのパラメータを使用できないため、シークレットを利用する場合はApacheのバージョンアップ、または後述のTomcat側設定で**secretRequired**を`false`にする対応が必要です。
* **ProxyPreserveHost:** バックエンドに対してオリジナルのHostヘッダ（`example.com`）を渡す設定です。AJPプロトコルではHostヘッダが元々保持されるため必須ではありませんが、明示的にOnにしておくことで将来的な設定変更時にも意図したホスト名が伝わるよう保証できます。

### Tomcat 側の AJP コネクタ設定

Tomcat側では、`$CATALINA_BASE/conf/server.xml` 内の `<Connector>` 要素でAJPコネクタを有効化・設定します。Tomcat 10.1ではデフォルトでAJPコネクタ（8009番ポート）がコメントアウトされている場合があるため、必要に応じて以下のように設定を追加・編集してください。

```xml
<!-- Tomcat server.xml の設定例 -->
<Connector protocol="AJP/1.3"
           address="192.168.1.10"               <!-- Apacheサーバからの接続のみ受け入れる内部IP -->
           port="8009"
           redirectPort="8443"
           secretRequired="true"
           secret="MY_AJP_SECRET"
           maxThreads="200"
           allowedRequestAttributesPattern="^$"
           tomcatAuthentication="false" />
```

**設定解説:**

* **address:** コネクタが待ち受けるネットワークインターフェイスを指定します。上記例では `192.168.1.10`（Tomcatサーバ自身の内部IPアドレス）を指定し、Apacheサーバからの接続のみ受け付けるよう制限しています。ApacheとTomcatを同一ホスト上で動作させる場合は `"127.0.0.1"` を指定することでループバックインターフェイスのみにバインドできます。
* **port:** AJPリスナのポート番号です。デフォルトは8009ですが、必要に応じて変更可能です。ファイアウォール設定およびApache側のProxyPass設定と整合させてください。
* **redirectPort:** Tomcat内のWebアプリケーションで、HTTP→HTTPSリダイレクトが必要な場合に使用されるポート番号です。通常は8443や443を指定します（Apacheが443でSSL終端する構成では、この設定は実質参照されません）。
* **secretRequired／secret:** AJPコネクタのセキュリティ強化のためのパラメータです。`secretRequired="true"` の場合、**secret** に設定した文字列と一致するシークレットを持つクライアント（ここではApache）からのAJP接続のみを許可します。`secretRequired` を`false`に設定すればシークレットなしで接続可能ですが、Tomcat公式が指摘するようにこの設定は信頼できるネットワーク内でのみ使用すべきです。
* **maxThreads:** AJPコネクタが使用できるワーカースレッドの最大数です。Apache経由で同時処理するリクエスト数に応じて適切な値を設定します（Tomcatのデフォルトは200）。Apache側で許可する最大接続数とのバランスも考慮してください。
* **allowedRequestAttributesPattern:** AJP経由でTomcatに渡すリクエスト属性名を許可するパターンを正規表現で指定します。デフォルトは`null`（空パターン、つまり任意の属性名を許可しない）であり、**`^$`** の指定はそれを明示しています。一般的なmod\_proxy\_ajp経由の運用では、SSL情報やロードバランサ情報などTomcatが想定する属性以外を送る必要はないため、この設定を緩和する必要はありません。
* **tomcatAuthentication:** Apache側でユーザ認証を実施し、その結果（ユーザ名）をTomcatに引き継ぐ場合は `false` を指定します。この場合、Apacheは認証ユーザ名をリクエスト属性(`REMOTE_USER`)としてTomcatに渡し、Tomcat側では自身で認証を行わずにそのユーザを信頼します。デフォルト値は `true` であり、Tomcatが独自に認証処理を行う動作となります。必要に応じて **tomcatAuthorization** を`true`に設定すれば、Apacheで認証されたユーザをTomcatでも認証済みとみなし、適切なロールを割り当てたアクセス制御（役割に基づく認可）を行うこともできます。

以上の設定を行ったら、Apache HTTP Server と Tomcat を再起動し、Apache経由でTomcatのアプリケーションに正常にアクセスできることを確認します。Apache側のアクセスログ～エラーログおよびTomcat側のログをチェックし、AJPコネクタでの連携が想定通り動作していることを検証してください。これが、Apache 2.4.37 と Tomcat 10.1 を別ホスト上で mod\_proxy\_ajp（AJPプロトコル）により連携させる際の構成ガイドとなります。

**参考資料:** 本ガイドの内容は Apache HTTP Server 公式ドキュメントおよび Apache Tomcat公式サイトのドキュメントに基づいています。各種パラメータの詳細についてはそれぞれの公式マニュアル（[Apache mod\_proxy\_ajp Module](https://httpd.apache.org/docs/2.4/mod/mod_proxy_ajp.html)、[Tomcat AJP Connector](https://tomcat.apache.org/tomcat-10.1-doc/config/ajp.html)等）も併せて参照してください。
