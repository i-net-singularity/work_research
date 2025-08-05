## 何が起きているか

```
javax.net.ssl.SSLHandshakeException
│  PKIX path building failed
│  SunCertPathBuilderException: unable to find valid certification path
```

は **Java が接続先（Maven Central・社内 Nexus など）の TLS 証明書を信頼できない** ときに必ず出ます。
`./mvnw` で発生する場合でも原因は **JDK (= JAVA\_HOME) が保持する trust store** にあります。 Maven Wrapper が展開する Maven 自体には trust store が無いからです。([Stack Overflow][1], [Stack Overflow][2])

---

## 原因を絞り込むチェックリスト

| チェック                                         | 典型的な現象                                                               | 対処概要                                      |
| -------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------- |
| 1. どの URL で失敗?                               | `./mvnw -X` で “Could not transfer artifact … from/to **(ホスト名)**” が出る | 失敗したホストを openssl で確認 (下記手順)               |
| 2. Public CA サイト? (例: repo.maven.apache.org) | **古い CA バンドル / 古い JDK** が多い                                          | `dnf update ca-certificates` + JDK を最新版へ  |
| 3. 社内リポジトリ or プロキシで MITM?                    | アドレスが \*.intra など                                                    | 社内 CA を trust store にインポート                |
| 4. Temurin など mise JDK?                      | `/opt/mise/installs/java/.../cacerts` が独立                            | system CA をリンク or インポート                   |
| 5. Maven 3.8+ で HTTP をブロックされている?             | エラーメッセージに “blocked”                                                  | HTTPS 化 or settings.xml `<blocked>false>` |

---

## 解決ステップ（RHEL 8.10 で Temurin17 を使っている例）

> **★ まず “どの証明書で失敗しているか” を特定**

```bash
# 1) Maven 詳細ログを見る
./mvnw -U -X clean package 2>&1 | tee mvn-debug.log
#   → 失敗 URL をメモ (例: nexus.company.local:8443)

# 2) サーバの証明書チェーンを確認
openssl s_client -connect nexus.company.local:8443 -servername nexus.company.local \
  -showcerts </dev/null | openssl x509 -noout -issuer -subject -dates
#   Verify return code: 21 (unable to verify the first certificate) なら CA 不足
```

### 1. Public CA サイトなら **CA バンドルを更新**

```bash
sudo dnf update -y ca-certificates
sudo update-ca-trust extract        # trust store を再生成
mise install java@temurin-17.0.11   # JDK も最新化
```

RHEL の rpm 版 OpenJDK はシステム trust store を参照しますが、
Temurin など tarball JDK は **独自の `$JAVA_HOME/lib/security/cacerts`** を使うため最新版でないと CA が欠けていることがあります。([Stack Overflow][3])

### 2. 社内 CA を追加

```bash
# ① システムへ登録  (全アプリ共通)
sudo cp corp-rootCA.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract

# ② Temurin など “個別 cacerts” へも取り込み
JAVA_HOME=$(mise where java)            # mise が指す JDK
sudo keytool -importcert -trustcacerts \
     -alias corp-root -file corp-rootCA.pem \
     -keystore "$JAVA_HOME/lib/security/cacerts" \
     -storepass changeit -noprompt
```

> **複数 JDK を使い分ける場合は**
>
> * それぞれの `$JAVA_HOME/lib/security/cacerts` に同じ CA を入れる
> * もしくは 1 つの共通 truststore を作り `MAVEN_OPTS="-Djavax.net.ssl.trustStore=/path/truststore.jks"` を渡す

### 3. プロキシ経由なら `<proxy>` + CA

```xml
<!-- ~/.m2/settings.xml -->
<proxies>
  <proxy>
    <id>corp-proxy</id>
    <active>true</active>
    <protocol>https</protocol>
    <host>proxy.internal</host><port>3128</port>
    <nonProxyHosts>*.intra|localhost</nonProxyHosts>
  </proxy>
</proxies>
```

プロキシが自己署名 CA を使う場合は **Step 2 で CA を追加** してください。

### 4. 一時回避（非推奨）

```bash
./mvnw clean package \
  -Dmaven.wagon.http.ssl.insecure=true \
  -Dmaven.wagon.http.ssl.allowall=true        # 全証明書を信頼
```

※ビルドは通りますが MITM 攻撃を防げません。恒久策を必ず取ること。([Stack Overflow][4])

---

## まとめチェックリスト

| ✓                                                     | やったこと |
| ----------------------------------------------------- | ----- |
| ☐ `./mvnw -X` で失敗 URL を特定                             |       |
| ☐ `openssl s_client` で “Verify return code: 0” になるか確認 |       |
| ☐ `ca-certificates` + JDK を更新                         |       |
| ☐ 社内 CA を **system trust** & **各 JDK cacerts** に取り込み  |       |
| ☐ (必要なら) settings.xml に proxy / mirror を設定            |       |
| ☐ 再度 `./mvnw clean package` が成功することを確認                |       |

これで大抵の **PKIX path building failed** は解消できます。 試してみてください！

[1]: https://stackoverflow.com/questions/25911623/problems-using-maven-and-ssl-behind-proxy?utm_source=chatgpt.com "Problems using Maven and SSL behind proxy"
[2]: https://stackoverflow.com/questions/37710721/maven-repository-sun-security-validator-validatorexception-pkix-path-building-f?utm_source=chatgpt.com "maven repository sun.security.validator.ValidatorException: ..."
[3]: https://stackoverflow.com/questions/75578686/java-maven-project-in-vscode-unable-to-find-valid-certification-path-to-request/76429692?utm_source=chatgpt.com "Java Maven project in VSCode: unable to find valid ..."
[4]: https://stackoverflow.com/questions/21252800/how-to-tell-maven-to-disregard-ssl-errors-and-trusting-all-certs?utm_source=chatgpt.com "How to tell Maven to disregard SSL errors (and trusting all ..."
