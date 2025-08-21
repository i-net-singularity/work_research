短く結論から。

**結論**

* **同時起動は可能**です。1つのJarに複数のジョブ（機能A/B）が入っていても、

  * ①Jarを**2プロセス**で起動して各プロセスで別ジョブを走らせる、または
  * ②**非同期JobLauncher**（`TaskExecutor`付き）で**同一JVM内で並列起動**
    のどちらかで同時に動かせます。標準の起動（1回の実行で1ジョブ）は**順次実行になりがち**なので、真の並列は上記いずれかを使うのが確実です。
* **ログは同一ファイルに時系列で“混ざって”出力**されます（完全な時刻順の保証はありません）。

  * **同一JVM内**なら行単位は壊れずに混在します。
  * **別JVM（2プロセス）で同一ファイル**に書く場合、**logbackの`prudent`モード**を有効化しないと、**行の競合やローテーション競合**のリスクがあります。

---

## 実務上のおすすめ

### 1) いちばん安全：ジョブごとにログファイルを分ける

`SiftingAppender`＋MDCで**ジョブ名別ログ**に振り分けると混ざりません。

```xml
<!-- logback(-spring).xml -->
<appender name="SIFT" class="ch.qos.logback.classic.sift.SiftingAppender">
  <discriminator class="ch.qos.logback.classic.sift.MDCBasedDiscriminator">
    <key>job</key>
    <defaultValue>unknown</defaultValue>
  </discriminator>
  <sift>
    <appender name="JOB-${job}" class="ch.qos.logback.core.rolling.RollingFileAppender">
      <file>/var/log/batch/${job}.log</file>
      <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
        <fileNamePattern>/var/log/batch/${job}.%d{yyyy-MM-dd}.log</fileNamePattern>
        <maxHistory>14</maxHistory>
      </rollingPolicy>
      <encoder>
        <pattern>%d %-5level [%thread] [%X{job}] %logger - %msg%n</pattern>
      </encoder>
    </appender>
  </sift>
</appender>

<root level="INFO">
  <appender-ref ref="SIFT"/>
</root>
```

ジョブ開始時にMDCへジョブ名を入れます（リスナでOK）。

```java
@Component
public class JobMdcListener implements JobExecutionListener {
  @Override public void beforeJob(JobExecution je) {
    MDC.put("job", je.getJobInstance().getJobName());
  }
  @Override public void afterJob(JobExecution je) {
    MDC.remove("job");
  }
}
```

### 2) 同一ファイルに混在させるときの最低限

* **別JVMから同一ファイルへ出力するなら**、`prudent`を必ずオン（安全書き込み）。
* パターンに`[%X{job}]`や`[%thread]`を入れて**どのジョブの行か分かるように**。

```xml
<appender name="FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
  <file>/var/log/batch/app.log</file>
  <prudent>true</prudent> <!-- 複数JVM対策 -->
  <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
    <fileNamePattern>/var/log/batch/app.%d{yyyy-MM-dd}.log</fileNamePattern>
    <maxHistory>14</maxHistory>
  </rollingPolicy>
  <encoder>
    <pattern>%d %-5level [%thread] [%X{job}] %logger - %msg%n</pattern>
  </encoder>
</appender>
```

> 注: `prudent=true`時は**サイズベースのローテーションは不可**など制約があるため、**時間ベース**のローテーションを使ってください。

---

## 同時起動のやり方（代表例）

* **2プロセス方式**（推奨・分かりやすい）
  Jarを2回起動し、それぞれに「実行するジョブ名」を渡す。
* **同一JVM内並列**
  `SimpleJobLauncher`に`TaskExecutor`（例：`SimpleAsyncTaskExecutor`）を設定し、A/Bを**別スレッド**で`run()`。

---

## まとめ

* **同時起動は可能。**
* **同一ファイルに出すなら混在はします**（順序保証なし）。
* **安全性・可読性を重視するなら**「ジョブ別ファイル」or「`prudent`＋行にジョブ名」を強く推奨です。

必要なら、あなたの`logback.xml`と起動方法（コマンド）に合わせた**最小変更案**を書きます！
