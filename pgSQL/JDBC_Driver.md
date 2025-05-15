# PostgreSQL JDBCドライバ v42.2.29からv42.7.5への移行影響調査

## 接続プロパティ一覧と各バージョンのデフォルト値

以下の表に、PostgreSQL JDBCドライバ v42.2.29 および v42.7.5 で使用可能な主な接続プロパティと、それぞれのデフォルト値をまとめます。**太字**で示したプロパティは後述の通り新規追加されたものです（v42.2.29には存在しないもの）。なお、v42.2.29からv42.7.5の間で**デフォルト値が変更されたプロパティは確認されませんでした**（両バージョンで既存プロパティのデフォルト設定に差異はありません）。

| 接続プロパティ                                           | v42.2.29 デフォルト値                                         | v42.7.5 デフォルト値                                                 |
| ------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------- |
| `user`（ユーザ名）                                      | （必須項目、デフォルトなし）                                          | （必須項目、デフォルトなし）                                                 |
| `password`（パスワード）                                 | （省略可、デフォルトなし）                                           | （省略可、デフォルトなし）                                                  |
| `options`（接続時のサーバパラメータ指定）                         | （省略時指定なし）                                               | （省略時指定なし）                                                      |
| `ssl`（SSL接続を有効化）                                  | false（指定時にSSL有効）                                        | false（同上）                                                      |
| `sslfactory`（カスタムSSLSocketFactoryクラス）             | `org.postgresql.ssl.LibPQFactory`                       | `org.postgresql.ssl.LibPQFactory`                              |
| `sslfactoryarg`（sslfactoryに渡す引数）※非推奨              | （デフォルトなし）                                               | （デフォルトなし）                                                      |
| `sslmode`（SSLモード）                                 | `prefer`                                                | `prefer`                                                       |
| **`sslNegotiation`**（SSLネゴシエーション方式）               | （v42.2.29では未対応）                                         | `postgres`（従来どおり）<br/>※PG 17+では`direct`指定可                     |
| `sslcert`（クライアント証明書パス）                            | `defaultdir/postgresql.crt`                             | `defaultdir/postgresql.crt`                                    |
| `sslkey`（クライアント秘密鍵パス）                             | `defaultdir/postgresql.pk8`                             | `defaultdir/postgresql.pk8`                                    |
| `sslrootcert`（信頼するCA証明書パス）                        | `defaultdir/root.crt`                                   | `defaultdir/root.crt`                                          |
| `sslhostnameverifier`（ホスト名検証クラス）                  | （v42.2.5で導入）`org.postgresql.ssl.PGjdbcHostnameVerifier` | `org.postgresql.ssl.PGjdbcHostnameVerifier`                    |
| **`sslpassword`**（SSL鍵ファイル用パスワード）                 | （v42.2.29では未対応）                                         | `null`（省略時はConsoleで入力）                                         |
| **`sslpasswordcallback`**（SSLパスワード提供クラス）          | （v42.2.29では未対応）                                         | `org.postgresql.ssl.jdbc4.LibPQFactory.ConsoleCallbackHandler` |
| `sslResponseTimeout`（SSL応答タイムアウト）                 | なし※                                                     | 5000（ms）                                                       |
| `protocolVersion`（プロトコルバージョン指定）                   | null（自動）                                                | null（自動）                                                       |
| `loggerLevel`（ログレベル）                              | （使用されず）                                                 | （使用されず）                                                        |
| `loggerFile`（ログ出力先ファイル）                           | （使用されず）                                                 | （使用されず）                                                        |
| `allowEncodingChanges`（エンコーディング変更許可）              | false                                                   | false                                                          |
| `logUnclosedConnections`（未クローズ接続のログ）              | false                                                   | false                                                          |
| `autosave`（自動セーブポイント）                             | `never`                                                 | `never`                                                        |
| `cleanupSavepoints`（セーブポイント開放）                    | false                                                   | false                                                          |
| **`channelBinding`**（チャネルバインディング）                 | （v42.2.29では未対応）                                         | `prefer`（SSL有効時）※PGサーバSSL対応時                                   |
| `binaryTransfer`（対応型のバイナリ転送）                      | true                                                    | true                                                           |
| `binaryTransferEnable`（バイナリ転送有効リスト）               | （空文字列＝個別指定なし）                                           | （空文字列）                                                         |
| `binaryTransferDisable`（バイナリ転送無効リスト）              | （空文字列）                                                  | （空文字列）                                                         |
| `databaseMetadataCacheFields`（メタデータキャッシュ項目数）      | 65536                                                   | 65536                                                          |
| `databaseMetadataCacheFieldsMiB`（メタデータキャッシュ容量MiB） | 5                                                       | 5                                                              |
| `prepareThreshold`（サーバ側プリペア段階への回数）                | 5                                                       | 5                                                              |
| `preparedStatementCacheQueries`（ステートメントキャッシュ数）    | 256                                                     | 256                                                            |
| `preparedStatementCacheSizeMiB`（ステートメントキャッシュ容量）   | 5                                                       | 5                                                              |
| `preferQueryMode`（クエリ実行モード）                       | `extended`（拡張プロトコル）                                     | `extended`                                                     |
| `defaultRowFetchSize`（フェッチ行数）                     | 0（全件一括）                                                 | 0（全件一括）                                                        |
| `loginTimeout`（ログイン試行タイムアウト）                      | 0（無制限）                                                  | 0（無制限）                                                         |
| `connectTimeout`（接続ソケットタイムアウト）                    | 10（秒）                                                   | 10（秒）                                                          |
| `socketTimeout`（ソケット読み取りタイムアウト）                   | 0（無制限）                                                  | 0（無制限）                                                         |
| `cancelSignalTimeout`（キャンセル用接続タイムアウト）             | 10（秒）                                                   | 10（秒）                                                          |
| `tcpKeepAlive`（TCP Keep-Alive）                    | false                                                   | false                                                          |
| `tcpNoDelay`（Nagleアルゴリズム無効化）                      | true                                                    | true                                                           |
| `unknownLength`（未知サイズ型の長さ）                        | `Integer.MAX_VALUE`                                     | `Integer.MAX_VALUE`                                            |
| `stringtype`（`setString()`パラメータ型）                 | `VARCHAR`（null扱い）                                       | `VARCHAR`（null扱い）                                              |
| `ApplicationName`（アプリケーション名）                      | `PostgreSQL JDBC Driver`                                | `PostgreSQL JDBC Driver`                                       |
| `kerberosServerName`（Kerberosサービス名）               | `postgres`                                              | `postgres`                                                     |
| `jaasApplicationName`（JAAS設定名）                    | `pgjdbc`                                                | `pgjdbc`                                                       |
| `jaasLogin`（JAASログイン実施）                           | true                                                    | true                                                           |
| `gssEncMode`（GSSAPI暗号化モード）                        | `allow`                                                 | `allow`                                                        |
| `gsslib`（SSPI/GSSAPI強制指定）                         | `auto`                                                  | `auto`                                                         |
| `gssResponseTimeout`（GSS応答待ちタイムアウト）               | 5000（ms）                                                | 5000（ms）                                                       |
| `sspiServiceClass`（SSPIサービスクラス名）                  | `POSTGRES`                                              | `POSTGRES`                                                     |
| `useSpnego`（SSPIでSPNEGO使用）                        | false                                                   | false                                                          |
| **`sendBufferSize`**（ソケット送信バッファ）                  | （v42.2.29では未対応）                                         | -1（OS依存のデフォルト）                                                 |
| **`maxSendBufferSize`**（送信バッファ上限）                 | （v42.2.29では未対応）                                         | 8192 バイト                                                       |
| **`receiveBufferSize`**（ソケット受信バッファ）               | （v42.2.29では未対応）                                         | -1（OSデフォルト）                                                    |
| `readOnly`（接続を読み取り専用に）                            | false                                                   | false                                                          |
| `readOnlyMode`（読み取り専用モード動作）                       | `transaction`                                           | `transaction`                                                  |
| `disableColumnSanitiser`（列名小文字変換無効）               | false（off）                                              | false（off）                                                     |
| `assumeMinServerVersion`（サーバ最小バージョン想定）            | null                                                    | null                                                           |
| `currentSchema`（初期検索パスschema）                     | null                                                    | null                                                           |
| `targetServerType`（接続先サーバ種別）                      | `any`                                                   | `any`                                                          |
| `hostRecheckSeconds`（ホスト状態再チェック間隔）                | 10 秒                                                    | 10 秒                                                           |
| `loadBalanceHosts`（ホスト負荷分散）                       | false                                                   | false                                                          |
| `socketFactory`（カスタムSocketFactory）                | null                                                    | null                                                           |
| `socketFactoryArg`（上記への引数）※非推奨                    | （デフォルトなし）                                               | （デフォルトなし）                                                      |
| `reWriteBatchedInserts`（バッチINSERT最適化）             | false                                                   | false                                                          |
| `replication`（ウォルセンダーモード）                         | false                                                   | false                                                          |
| `escapeSyntaxCallMode`（JDBCエスケープ呼出しの扱い）           | `select`                                                | `select`                                                       |
| **`maxResultBuffer`**（結果セット読み取りバッファ上限）            | （v42.2.9以前未対応、v42.2.10で導入）                              | null（無制限）                                                      |
| **`adaptiveFetch`**（バッファ自動調整フェッチ）                 | （v42.2.10で導入）                                           | false                                                          |
| **`adaptiveFetchMinimum`**（自動フェッチ下限行数）            | （v42.2.10で導入）                                           | 0                                                              |
| **`adaptiveFetchMaximum`**（自動フェッチ上限行数）            | （v42.2.10で導入）                                           | -1（無限大）                                                        |
| `logServerErrorDetail`（サーバエラー詳細出力）                | true（詳細を出力）                                             | true（詳細を出力）                                                    |
| **`quoteReturningIdentifiers`**（RETURNING列の引用符付与） | （v42.3.0で導入）                                            | false（無効）                                                      |
| `authenticationPluginClassName`（認証プラグイン実装クラス）     | null                                                    | null                                                           |

※表中「（v42.xで導入）」と記載したプロパティは、そのバージョン以降で追加された新機能です。v42.2.29には存在せず、v42.7.5では使用可能となっています。

上記の通り、**v42.2.29からv42.7.5の間に**既存プロパティのデフォルト値そのものに変更は確認されませんでした。ただし、**新たに追加されたプロパティ**にはそれぞれ初期デフォルト値が設定されています（表中に示した通り）。例えば、`connectTimeout`はv42.2.29以前より**10秒**がデフォルトで（9.4系ドライバの後期より導入）、v42.7.5でも同様です。また`tcpKeepAlive`は両バージョンともデフォルト無効（false）です。

以下では、とくに**SSL/TLS接続に関連するプロパティの変更点**および**SSL接続多数時のEOF検出エラーに関する考察**について詳述します。

## SSL/TLS関連プロパティの変更・追加点

PostgreSQL JDBCドライバのSSL/TLS接続周りでは、v42.2.29からv42.7.5までに以下のような強化・変更が行われています。

* **`ssl=true`指定時の挙動強化（ホスト検証のデフォルト有効化）**: 42.2.5以降、接続URLに`ssl=true`を指定するとデフォルトで`sslmode=verify-full`と同等の動作をするようになりました。すなわち、サーバ証明書の妥当性チェックとホスト名検証が自動的に有効になります。**これはlibpq（psql）とは異なる動作**であり、libpqでは明示しない限り証明書検証なしのSSL接続がデフォルトです。この変更により、JDBCドライバではMITM攻撃防止のため証明書認証とホスト名照合が標準で有効となっています（`ssl=true`の場合）。**v42.2.29では既にこの挙動が実装済み**であり、v42.7.5でも同様です。したがって、移行後も`ssl=true`指定時は証明書類（`sslrootcert`など）の適切な設定が必要です。

* **SSL接続モード指定`sslmode`**: 上記の通りデフォルトは両バージョンとも`prefer`です。`prefer`はサーバがSSLをサポートしていればSSL接続を行い、証明書やホスト検証は行わないモードです。**42.2.5で`ssl=true`時にデフォルト検証が有効化された**ものの、`sslmode`パラメータ自体のデフォルト値（`prefer`）に変更はありません。検証を無効にしたい場合は明示的に`sslmode=require`（暗号化のみ）や`sslmode=allow`等を指定する必要があります。

* **クライアント証明書のPKCS#12サポート**: 42.2.9でPKCS#12形式のクライアント証明書（拡張子`.p12`）がサポートされ、42.2.16では`.pfx`拡張子も認識されるようになりました。この場合、`sslkey`に.p12/.pfxファイルを指定し、`sslcert`設定は無視されます。v42.2.29およびv42.7.5はいずれもPKCS#12形式に対応しています。また、**42.2.9以降でパスワード付き鍵への対応**が強化されており、v42.7.5では以下の新プロパティが利用可能です:

  * `sslpassword` … パスワード保護されたSSL鍵ファイルのパスワードをドライバに与えるためのオプションです。デフォルトはnullで、省略時にはコンソールにパスワード入力を促すハンドラが動作します。**42.2.29にはこのプロパティはなく**、パスワード付き鍵利用時は対話的入力（もしくは接続失敗）が発生していました。
  * `sslpasswordcallback` … `sslpassword`を取得するコールバッククラスを指定できます（デフォルトはコンソール入力用のハンドラ実装）。これもv42.3以降で追加された拡張です。

* **ホスト名検証のカスタマイズ**: 42.2.5で導入された`sslhostnameverifier`プロパティにより、ホスト名検証の実装クラスを差し替えることが可能になっています。デフォルトはJDBCドライバ組み込みの`PGjdbcHostnameVerifier`クラスであり、**v42.2.29以降このプロパティが利用可能**です。カスタムの検証ロジックが必要な場合にこのクラス名を指定できます。

* **直接SSLネゴシエーションモードの追加**: PostgreSQL 17以降のサーバでは、クライアントが*いきなり*SSLハンドシェイクを開始する「direct」モードがサポートされました。これを利用するため、v42.7.4で新プロパティ`sslNegotiation`が追加されています。デフォルト値`postgres`では従来通り「まずGSSAPIネゴシエーションを試行し、次にSSL要求を送る」段階的な交渉を行います。一方`sslNegotiation=direct`を指定すると、ドライバは即座にSSLハンドシェイクを開始し、往復1回分のレイテンシを削減します。**v42.2系にはこの機能は無く**、v42.7.5で新たに選択可能となっています。なお`direct`モードはサーバ側もPostgreSQL 17以降である必要があります。デフォルトは従来互換の`postgres`モードなので、明示的に指定しない限り動作に変化はありません。

* **SCRAM認証でのチャネルバインディング対応**: PostgreSQL 11+ではSCRAM-SHA-256認証でTLSチャネルバインディング（SCRAM-SHA-256-PLUS）が利用可能です。JDBCドライバではv42.7.4にてSCRAMライブラリを更新しチャネルバインディングを正式サポートしました（PR #3188）。新しく追加された`channelBinding`プロパティで利用ポリシーを設定できます（`require`/`prefer`/`disable`）。**v42.2.29ではチャネルバインディングはサポートされておらず**、SCRAM認証時は常に従来の非バインディング方式で接続していました。v42.7.5ではデフォルト`prefer`により、サーバとクライアント双方が対応していれば自動的にバインディング付きSCRAMを用います。これにより認証の安全性が向上しますが、環境によってはわずかに接続時の負荷が増加する可能性があります。

以上のように、SSL/TLS設定周りでは **新規プロパティの追加** と **デフォルト挙動のセキュリティ強化** が行われています。v42.2.29から移行する際は、証明書ファイルや接続URLパラメータの設定が新バージョンの検証強化や新機能に合致しているか確認してください。例えば、`ssl=true`利用時には`root.crt`やサーバ証明書のホスト名が適切に設定されている必要があります。また、大量接続環境でSSLハンドシェイク時間が問題になる場合、PostgreSQL 17以降であれば`sslNegotiation=direct`の検討、あるいはタイムアウト設定の見直しも有用です（次項参照）。

## SSL大量接続時の「EOF検出」エラーとタイムアウトに関する考察

ユーザ環境において、v42.7.5ドライバを使用しPostgreSQL 16.4または17.4サーバへの**SSL接続が多数発生すると「EOF検出」エラーがサーバ側に出力され、クライアント（JDBC側）ではタイムアウトとなる**現象が報告されています。これは、多数のSSLハンドシェイクが並行して行われる状況で、一部の接続が**タイムアウトに達して切断されてしまう**ことに起因すると考えられます。以下、その原因や関連する設定について考察します。

* **接続タイムアウト値（connectTimeout）による影響**: JDBCドライバの`connectTimeout`はデフォルト10秒に設定されています。大量の同時接続時には、サーバ側でハンドシェイク処理が滞り、一部の接続確立に10秒以上かかる可能性があります。この場合、クライアント側（ドライバ）がタイムアウトし接続を閉じてしまうため、サーバログには「SSL SYSCALL error: EOF detected」等のエラーが記録されます（クライアントがハンドシェイク途中で切断したことによる）。**対策**: 大規模環境では`connectTimeout`を十分大きく設定するか、必要に応じて0（無効）に設定してタイムアウトに起因する切断を防ぐことが考えられます。

* **SSL応答タイムアウト（sslResponseTimeout）**: ドライバはSSL要求後のサーバ応答（`SSLRequest`に対する`S`応答）を待つ時間として`sslResponseTimeout`も内部的に使用しています（デフォルト5000ms）。この値は`connectTimeout`より大きい場合は`connectTimeout`まで待つ仕様ですが、デフォルトでは5秒と短いため、同時接続集中時には初期応答待ちでタイムアウトが発生する可能性があります。**対策**: `sslResponseTimeout`はプロパティとして指定可能ですので、必要に応じて値を延長することで初期ハンドシェイク応答を待つ時間を増やせます（例：`sslResponseTimeout=15000`で15秒待機）。

* **ALPN直接交渉の活用**: 前述の`sslNegotiation=direct`を使用できる環境(PostgreSQL 17.0以降)では、**ハンドシェイクの往復回数を削減**できるため、同時大量接続時の待ち時間短縮が期待できます。デフォルトでは`postgres`（従来方式）なので明示的な設定が必要ですが、これにより1往復分応答を待つ必要がなくなり、タイムアウト発生のリスクを下げられる可能性があります。

* **SCRAMチャネルバインディングの負荷**: v42.7.5ではチャネルバインディング対応により、SCRAM認証時にTLSフィンガプリントの照合処理が追加で行われます。この処理自体は大きな負荷ではありませんが、大量並行時には積み重なってわずかな遅延要因となる可能性があります。もし認証部分でボトルネックが疑われる場合、一時的に`channelBinding=disable`としてチャネルバインディングを無効化し、挙動が改善するかを検証してみる余地があります（ただしセキュリティ強度とのトレードオフとなる点に留意）。

* **TCPレベルの設定**: ネットワーク機器やOSによる制限で、ハンドシェイクパケットがドロップ・遅延している可能性もあります。上位の問題とは少し異なりますが、サーバとクライアント間のネットワークがSSL接続の負荷に耐えられない場合、`tcpKeepAlive`等は直接の解決策にはなりません。しかし**PostgreSQLサーバ側の設定**として`ssl_prefer_server_ciphers`や使用する暗号スイートを調整し、ハンドシェイク処理を軽減することも考えられます。JDBCドライバ側では直接これらを制御するプロパティはありませんが（JVMのJSSE設定で調整）、サーバ・クライアント間のSSLハンドシェイクコストにも目を配る必要があります。

以上を踏まえると、**原因としてはJDBCドライバのタイムアウト設定**が大量同時接続時に相対的に短すぎることが主因であり、\*\*関連するプロパティは`connectTimeout`や`sslResponseTimeout`\*\*といえます。移行後にこの現象が発生する場合、これらの値を引き上げることで「EOF検出」による接続断を回避できる可能性があります。また、PostgreSQL 17環境であれば`sslNegotiation=direct`を有効にしてSSL接続確立を高速化することも有効でしょう。なお、v42.2.29からv42.7.5への移行自体でSSLハンドシェイクが遅くなる設定変更は基本的にありませんが、**チャネルバインディング対応などのセキュリティ強化により若干の処理増加**はありえます。そのため、大量接続環境では上記パラメータの調整によるチューニングが重要となります。

## まとめ

PostgreSQL JDBCドライバv42.2.29からv42.7.5への移行に際しては、**接続プロパティの追加・拡張**と**SSL関連機能のデフォルト挙動**に注意が必要です。表で列挙した通り、多くの新機能プロパティ（太字）がおもにv42.3以降で導入されており、SSL/TLS接続や認証方式の強化が図られています。デフォルト値自体に互換性問題はありませんが、`ssl=true`時の証明書検証やSCRAM認証のチャネルバインディング対応など、**セキュリティ設定の強化**によって必要となる設定ファイル（証明書類）の準備や、環境に応じたタイムアウト値の見直しが重要となります。特に、SSL接続を多数張るアプリケーションでは、**ドライバ側タイムアウト設定の調整**や\*\*PostgreSQL 17新機能（ALPN直接SSL）\*\*の活用によって、安定した接続確立を図ることが望ましいでしょう。

**参考文献**（公式ドキュメントおよびリリースノート）:

* PostgreSQL JDBC Driver Documentation – *Initializing the Driver / Connection Parameters*他
* PostgreSQL JDBC Driver Release Notes – v42.2.24, v42.3.0, v42.7.4 など
* PostgreSQL JDBC Driver Documentation – *Using SSL*
