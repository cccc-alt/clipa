import Foundation

struct ClassificationTestCase {
    let id: String
    let text: String
    let expectedTag: SmartTag?
    let kind: ClipKind
}

enum ClassificationCorpus {
    private static let jsonCases: [ClassificationTestCase] = [
        .init(id: "JSON-01", text: #"""
        {
          "name": "nginx",
          "version": "1.27",
          "replicas": 3
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-02", text: #"""
        [
          "docker",
          "kubernetes",
          "cilium"
        ]
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-03", text: #"""
        {
          "server": {
            "host": "127.0.0.1",
            "port": 8080
          },
          "enabled": true
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-04", text: #"""
        {
          "port": 443,
          "enabled": true,
          "description": null
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-05", text: #"""
        {
          "apiVersion": "apps/v1",
          "kind": "Deployment",
          "metadata": {
            "name": "nginx"
          },
          "spec": {
            "replicas": 3
          }
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-06", text: #"""
        {
          "name": "Clipa",
          "homepage": "https://example.com",
          "port": 443
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-07", text: #"""
        {
          "server": "192.168.1.10",
          "gateway": "192.168.1.1"
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-08", text: #"""
        {
          "admin": "admin@example.com",
          "enabled": true
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-09", text: #"""
        {
          "command": "kubectl get pods -A",
          "timeout": 30
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-10", text: #"{"name":"redis","port":6379,"enabled":true}"#, expectedTag: .json, kind: .text),
        .init(id: "JSON-11", text: #"{"name": nginx, "port": 80}"#, expectedTag: nil, kind: .text),
        .init(id: "JSON-12", text: #"""
        {
          "metadata": {
            "name": "nginx"
          },
          "spec": {
            "replicas": 3
          }
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-13", text: #"""
        {
          "timestamp": "2026-09-06T10:30:00Z",
          "level": "ERROR",
          "message": "connection failed"
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-14", text: #"""
        {
          "message": "Error: connection refused",
          "raw": "name: nginx",
          "url": "https://example.com"
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "JSON-15", text: #"""
        {
          "network": {
            "interface": "eth0",
            "address": "10.0.0.10",
            "gateway": "10.0.0.1"
          },
          "routes": [
            {
              "destination": "0.0.0.0/0",
              "via": "10.0.0.1"
            }
          ]
        }
        """#, expectedTag: .json, kind: .text)
    ]

    private static let yamlCases: [ClassificationTestCase] = [
        .init(id: "YAML-01", text: #"""
        name: nginx
        image: nginx:latest
        replicas: 3
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-02", text: #"""
        metadata:
          name: nginx
          namespace: default
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-03", text: #"""
        servers:
          - web01
          - web02
          - web03
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-04", text: #"""
        containers:
          - name: nginx
            image: nginx:latest
          - name: redis
            image: redis:latest
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-05", text: #"""
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: nginx
        spec:
          replicas: 3
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-06", text: #"""
        apiVersion: v1
        kind: Service
        metadata:
          name: nginx
        spec:
          selector:
            app: nginx
          ports:
            - port: 80
              targetPort: 8080
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-07", text: #"""
        ---
        name: nginx
        version: "1.0"
        enabled: true
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-08", text: #"""
        server:
          host: 0.0.0.0
          port: 8080
        database:
          host: localhost
          port: 5432
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-09", text: #"""
        api:
          endpoint: https://api.example.com/v1
          timeout: 30
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-10", text: #"""
        server:
          address: 192.168.1.10
          gateway: 192.168.1.1
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-11", text: #"""
        admin:
          name: Alice
          email: admin@example.com
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-12", text: #"""
        command:
          - kubectl
          - get
          - pods
          - --all-namespaces
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-13", text: #"""
        # nginx configuration
        server:
          port: 80
          host: localhost
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "YAML-14", text: "raw: 不是 JSON", expectedTag: nil, kind: .text),
        .init(id: "YAML-16", text: "kind: 说明", expectedTag: nil, kind: .text),
        .init(id: "YAML-15", text: #"""
        2026-09-05 18:21:26 +0000 decode failed: unable to decode response

        raw: 不是 JSON

        2026-09-05 18:23:48 +0000 decode failed: unable to decode response

        raw: 不是 JSON
        """#, expectedTag: nil, kind: .text)
    ]

    private static let logShapedCases: [ClassificationTestCase] = [
        .init(id: "LOG-01", text: "2026-09-06 10:00:01 INFO server started\n2026-09-06 10:00:02 INFO listening on port 8080", expectedTag: nil, kind: .text),
        .init(id: "LOG-02", text: "2026-09-06 10:01:23 ERROR connection refused", expectedTag: nil, kind: .text),
        .init(id: "LOG-03", text: "2026-09-06 10:02:10 WARN connection pool is almost full", expectedTag: nil, kind: .text),
        .init(id: "LOG-04", text: "2026-09-06 10:03:11 DEBUG request_id=abc123 retry=2", expectedTag: nil, kind: .text),
        .init(id: "LOG-05", text: "[INFO] server started\n[INFO] loading configuration\n[ERROR] database connection failed", expectedTag: nil, kind: .text),
        .init(id: "LOG-06", text: "2026-09-06 10:05:12 ERROR java.lang.RuntimeException: connection failed", expectedTag: nil, kind: .text),
        .init(id: "LOG-07", text: #"""
        Traceback (most recent call last):
          File "main.py", line 10, in <module>
            connect()
        ConnectionError: connection refused
        """#, expectedTag: nil, kind: .text),
        .init(id: "LOG-08", text: "2026-09-06 10:07:01 decode failed: invalid response format\n2026-09-06 10:07:02 retrying request", expectedTag: nil, kind: .text),
        .init(id: "LOG-09", text: "2026-09-06 10:08:20 +0000 decode failed: 未能读取数据，因为它的格式不正确。", expectedTag: nil, kind: .text),
        .init(id: "LOG-10", text: "2026-09-06 10:09:01 connection accepted\n2026-09-06 10:09:02 connection closed\n2026-09-06 10:09:03 connection accepted\n2026-09-06 10:09:04 connection closed", expectedTag: nil, kind: .text),
        .init(id: "LOG-11", text: "2026-09-06 10:10:01 ERROR configuration parsing failed\nserver: nginx\nport: 8080", expectedTag: nil, kind: .text),
        .init(id: "LOG-12", text: "2026-09-06 10:11:20 INFO request https://api.example.com/v1/users\n2026-09-06 10:11:21 ERROR response status=500", expectedTag: nil, kind: .text),
        .init(id: "LOG-13", text: "2026-09-06 10:12:01 INFO client=192.168.1.10 connected\n2026-09-06 10:12:02 WARN client=192.168.1.20 timeout", expectedTag: nil, kind: .text),
        .init(id: "LOG-14", text: #"2026-09-06 10:13:01 INFO response={"status":"ok","code":200}"#, expectedTag: nil, kind: .text),
        .init(id: "LOG-15", text: "2026-09-06 10:14:01 INFO config loaded\nmetadata:\n  name: nginx\nspec:\n  replicas: 3\n2026-09-06 10:14:02 INFO deployment completed", expectedTag: nil, kind: .text)
    ]

    private static let urlShapedCases: [ClassificationTestCase] = [
        .init(id: "URL-01", text: "https://example.com", expectedTag: nil, kind: .text),
        .init(id: "URL-02", text: "https://example.com/api/v1/users", expectedTag: nil, kind: .text),
        .init(id: "URL-03", text: "http://localhost:8080", expectedTag: nil, kind: .text),
        .init(id: "URL-04", text: "https://127.0.0.1:8443/health", expectedTag: nil, kind: .text),
        .init(id: "URL-05", text: "https://user:password@example.com/login", expectedTag: nil, kind: .text),
        .init(id: "URL-06", text: "https://example.com/search?q=kubernetes&page=2", expectedTag: nil, kind: .text),
        .init(id: "URL-07", text: "https://example.com/docs#network", expectedTag: nil, kind: .text),
        .init(id: "URL-08", text: "http://192.168.1.10:8080/api", expectedTag: nil, kind: .text),
        .init(id: "URL-09", text: #"https://example.com/api?filter={"status":"ok"}"#, expectedTag: nil, kind: .text),
        .init(id: "URL-10", text: "please open https://example.com and check the documentation", expectedTag: nil, kind: .text),
        .init(id: "URL-11", text: "https://", expectedTag: nil, kind: .text),
        .init(id: "URL-12", text: "example.com", expectedTag: nil, kind: .text),
        .init(id: "URL-13", text: "mailto:admin@example.com", expectedTag: nil, kind: .text),
        .init(id: "URL-14", text: "https://kubernetes.default.svc/api/v1/namespaces/default/pods", expectedTag: nil, kind: .text),
        .init(id: "URL-15", text: "2026-09-06 10:20:01 INFO GET https://api.example.com/v1/users", expectedTag: nil, kind: .text),

        .init(id: "URL-16", text: "https://github.com/aaa/bbb\nhttps://github.com/ccc/ddd\nname: nginx\nreplicas: 3", expectedTag: nil, kind: .text)
    ]

    private static let ipShapedCases: [ClassificationTestCase] = [
        .init(id: "IP-01", text: "192.168.1.1", expectedTag: nil, kind: .text),
        .init(id: "IP-02", text: "10.0.0.1", expectedTag: nil, kind: .text),
        .init(id: "IP-03", text: "127.0.0.1", expectedTag: nil, kind: .text),
        .init(id: "IP-04", text: "255.255.255.255", expectedTag: nil, kind: .text),
        .init(id: "IP-05", text: "0.0.0.0", expectedTag: nil, kind: .text),
        .init(id: "IP-06", text: "2001:db8::1", expectedTag: nil, kind: .text),
        .init(id: "IP-07", text: "::1", expectedTag: nil, kind: .text),
        .init(id: "IP-08", text: "2001:0db8:0000:0000:0000:ff00:0042:8329", expectedTag: nil, kind: .text),
        .init(id: "IP-09", text: "192.168.1.10:8080", expectedTag: nil, kind: .text),
        .init(id: "IP-10", text: "999.999.999.999", expectedTag: nil, kind: .text),
        .init(id: "IP-11", text: "192.168.1", expectedTag: nil, kind: .text),
        .init(id: "IP-12", text: "The server is running at 192.168.1.10.", expectedTag: nil, kind: .text),
        .init(id: "IP-16", text: "192.168.1.0/33", expectedTag: nil, kind: .text),
        .init(id: "IP-17", text: "2001:db8::1::2", expectedTag: nil, kind: .text),
        .init(id: "IP-18", text: "ab:cd", expectedTag: nil, kind: .text),
        .init(id: "IP-13", text: #"""
        server:
          address: 192.168.1.10
          gateway: 192.168.1.1
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "IP-14", text: "2026-09-06 10:30:01 INFO client=192.168.1.10 connected", expectedTag: nil, kind: .text),
        .init(id: "IP-15", text: #"""
        {
          "server": "192.168.1.10",
          "gateway": "192.168.1.1"
        }
        """#, expectedTag: .json, kind: .text)
    ]

    private static let emailShapedCases: [ClassificationTestCase] = [
        .init(id: "EMAIL-01", text: "admin@example.com", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-02", text: "alice@example.org", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-03", text: "support@company.co.jp", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-04", text: "dev.ops@example.com", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-05", text: "user+test@example.com", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-06", text: "network-team@example.com", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-07", text: "admin@dev.example.com", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-08", text: "admin@", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-09", text: "admin@example", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-10", text: "Please contact admin@example.com for support.", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-16", text: "admin@example..com", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-17", text: "admin@example.com>", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-18", text: "a..b@example.com", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-11", text: #"""
        {
          "email": "admin@example.com",
          "name": "Alice"
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "EMAIL-12", text: #"""
        admin:
          email: admin@example.com
          name: Alice
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "EMAIL-13", text: "2026-09-06 10:40:01 INFO sending notification to admin@example.com", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-14", text: "admin@example.com\nsupport@example.com\ndev@example.com", expectedTag: nil, kind: .text),
        .init(id: "EMAIL-15", text: "mailto:admin@example.com", expectedTag: nil, kind: .text)
    ]

    private static let commandShapedCases: [ClassificationTestCase] = [
        .init(id: "CMD-01", text: "git status", expectedTag: nil, kind: .text),
        .init(id: "CMD-02", text: "docker ps -a", expectedTag: nil, kind: .text),
        .init(id: "CMD-03", text: "kubectl get pods -A", expectedTag: nil, kind: .text),
        .init(id: "CMD-04", text: "cilium status", expectedTag: nil, kind: .text),
        .init(id: "CMD-05", text: "curl -I https://example.com", expectedTag: nil, kind: .text),
        .init(id: "CMD-06", text: "ssh user@192.168.1.10", expectedTag: nil, kind: .text),
        .init(id: "CMD-07", text: "kubectl get pods -A | grep nginx", expectedTag: nil, kind: .text),
        .init(id: "CMD-08", text: "export APP_ENV=production", expectedTag: nil, kind: .text),
        .init(id: "CMD-09", text: "docker compose up -d", expectedTag: nil, kind: .text),
        .init(id: "CMD-10", text: "curl https://api.example.com/v1/users", expectedTag: nil, kind: .text),
        .init(id: "CMD-11", text: "ping 192.168.1.1", expectedTag: nil, kind: .text),
        .init(id: "CMD-12", text: "git config user.email admin@example.com", expectedTag: nil, kind: .text),
        .init(id: "CMD-13", text: #"echo "name: nginx""#, expectedTag: nil, kind: .text),
        .init(id: "CMD-14", text: #"curl -X POST https://example.com/api -d '{"name":"nginx"}'"#, expectedTag: nil, kind: .text),
        .init(id: "CMD-15", text: "#!/bin/bash\n\nfor pod in $(kubectl get pods -o name); do\n  echo \"$pod\"\ndone", expectedTag: nil, kind: .text),
        .init(id: "CMD-16", text: "docker is a tool for running containers", expectedTag: nil, kind: .text),
        .init(id: "CMD-17", text: "npm is a package manager", expectedTag: nil, kind: .text),
        .init(id: "CMD-18", text: "python3 -m http.server 8000", expectedTag: nil, kind: .text),
        .init(id: "CMD-19", text: #"node -e "console.log(1)""#, expectedTag: nil, kind: .text)
    ]

    private static let realWorldYAMLCases: [ClassificationTestCase] = [
        .init(id: "RWY-01", text: #"""
        apiVersion: network.networkconfigoperator/v1
        kind: NetDevs
        metadata:
          name: ceos1
        spec:
          username: admin
          host: 172.20.20.2
          port: 80
          runningconfig:  |+
            hostname ceos1
            !
            interface Ethernet1
              no switchport
              ip address 10.0.0.1/24
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "RWY-02", text: #"""
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: gcp-devops-gke
          labels:
            app: web
        spec:
          replicas: 3
          selector:
            matchLabels:
              app: web
          template:
            spec:
              containers:
              - name: web
                image: nginx:1.27
                ports:
                - containerPort: 80
        """#, expectedTag: .yaml, kind: .text),
        .init(id: "RWY-03", text: #"""
        _schema-version: "3.3"
        ID: genai-mail-insights
        version: 0.0.1

        parameters:
          enable-parallel-deployments: true
          memory: 512
          timeout: 30
          region: ap-southeast-1
          logLevel: info
        build:
          builder: custom
        """#, expectedTag: .yaml, kind: .text),

        .init(id: "RWY-04", text: "结论: 成功\n原因: 网络正常\n备注: 无需处理\n结果: 通过", expectedTag: nil, kind: .text),
        .init(id: "RWY-05", text: "2026-09-11 10:00:01 ERROR connect failed\n2026-09-11 10:00:02 ERROR retry\n2026-09-11 10:00:03 INFO done", expectedTag: nil, kind: .text),
        .init(id: "RWY-06", text: "今天做了三件事 - 吃饭 - 睡觉 - 写代码，没有列表结构。\n第二行也是散文，只是提到 x: 1 这样的写法而已。", expectedTag: nil, kind: .text)
    ]

    private static let markdownCases: [ClassificationTestCase] = [
        .init(id: "MD-01", text: "# Title\n\nBody text\n\n- one\n- two", expectedTag: .markdown, kind: .text),
        .init(id: "MD-02", text: "## Heading\n\n```bash\necho hi\n```\n\n```json\n{}\n```", expectedTag: .markdown, kind: .text),
        .init(id: "MD-03", text: "| Name | Value |\n| --- | --- |\n| a | 1 |", expectedTag: .markdown, kind: .text),
        .init(id: "MD-04", text: "# 备注\n\n**重点** 见 [文档](https://example.com)", expectedTag: .markdown, kind: .text),

        .init(id: "MD-05", text: "详情见 [文档](https://example.com)，有问题随时联系。", expectedTag: nil, kind: .text)
    ]

    private static let crossCases: [ClassificationTestCase] = [
        .init(id: "CONF-01", text: #"""
        {
          "endpoint": "https://example.com"
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "CONF-02", text: #"""
        {
          "address": "192.168.1.10"
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "CONF-03", text: #"""
        {
          "email": "admin@example.com"
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "CONF-04", text: #"""
        {
          "timestamp": "2026-09-06T10:00:00Z",
          "level": "ERROR",
          "message": "connection failed"
        }
        """#, expectedTag: .json, kind: .text),
        .init(id: "CONF-05", text: "endpoint: https://example.com\ntimeout: 30", expectedTag: .yaml, kind: .text),
        .init(id: "CONF-06", text: "server:\n  address: 192.168.1.10", expectedTag: .yaml, kind: .text),
        .init(id: "CONF-07", text: "command:\n  - kubectl\n  - get\n  - pods", expectedTag: .yaml, kind: .text),
        .init(id: "CONF-08", text: "2026-09-06 11:00:01 INFO configuration loaded\nserver:\n  host: 127.0.0.1\n  port: 8080\n2026-09-06 11:00:02 INFO server started", expectedTag: nil, kind: .text),
        .init(id: "CONF-09", text: #"2026-09-06 11:01:01 INFO response={"status":"ok"}"#, expectedTag: nil, kind: .text),
        .init(id: "CONF-10", text: "2026-09-06 11:02:01 INFO client=192.168.1.10 connected", expectedTag: nil, kind: .text),
        .init(id: "CONF-11", text: "2026-09-06 11:03:01 INFO GET https://example.com/api", expectedTag: nil, kind: .text),
        .init(id: "CONF-12", text: "curl https://example.com", expectedTag: nil, kind: .text),
        .init(id: "CONF-13", text: "ssh root@192.168.1.10", expectedTag: nil, kind: .text),
        .init(id: "CONF-14", text: "git config user.email admin@example.com", expectedTag: nil, kind: .text),
        .init(id: "CONF-15", text: "mailto:admin@example.com", expectedTag: nil, kind: .text)
    ]

    private static let privacyCases: [String] = [
        #"password="FAKE_TEST_PASSWORD_123""#,
        #"api_key="FAKE_TEST_API_KEY_123""#,
        #"access_token="FAKE_TEST_ACCESS_TOKEN""#,
        """
        -----BEGIN PRIVATE KEY-----
        FAKE_TEST_KEY
        -----END PRIVATE KEY-----
        """,
        "Authorization: Bearer FAKE_TEST_TOKEN"
    ]

    static func run() -> Int32 {
        let cases = jsonCases + yamlCases + logShapedCases + urlShapedCases
            + ipShapedCases + emailShapedCases + commandShapedCases
            + realWorldYAMLCases + markdownCases + crossCases
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipaClassificationCorpus-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "ClipaClassificationCorpus-\(UUID().uuidString)")!
        let store = ClipStore(
            baseDirectory: dir,
            settingsStore: SettingsStore(
                defaults: defaults
            )
        )

        var passed = 0
        var failed = 0
        for test in cases {
            let actual = ClassificationEngine.classify(test.text)
            if actual == test.expectedTag {
                passed += 1
            } else {
                failed += 1
                print("[FAIL] \(test.id): expected=\(test.expectedTag?.rawValue ?? "nil") actual=\(actual?.rawValue ?? "nil")")
            }

            let draft = NewClip(
                kind: test.kind,
                text: test.text,
                contentHash: ContentHasher.hash(text: test.text)
            )
            _ = store.insert(draft, allowAutoPause: false)
        }

        for text in privacyCases {
            let draft = NewClip(
                kind: .text,
                text: text,
                contentHash: ContentHasher.hash(text: text)
            )
            _ = store.insert(draft, allowAutoPause: false)
        }

        let reloaded = ClipStore(
            baseDirectory: dir,
            settingsStore: SettingsStore(
                defaults: UserDefaults(
                    suiteName: "ClipaClassificationReload-\(UUID().uuidString)"
                )!
            )
        )
        for test in cases {
            guard let expected = test.expectedTag else { continue }
            guard let stored = reloaded.items.first(where: {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    == test.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }) else {
                failed += 1
                print("[FAIL] \(test.id): not found in database")
                continue
            }
            let expectedKind = SmartClassifier.kind(
                for: expected,
                fallbackKind: test.kind
            )
            if stored.smartTag == expected && stored.kind == expectedKind {
                passed += 1
            } else {
                failed += 1
                print(
                    "[FAIL] \(test.id) DB: expected tag=\(expected.rawValue)"
                        + " kind=\(expectedKind.rawValue)"
                        + " actual tag=\(stored.smartTag.rawValue)"
                        + " kind=\(stored.kind.rawValue)"
                )
            }
        }

        for text in privacyCases {
            guard let stored = reloaded.items.first(where: {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    == text.trimmingCharacters(in: .whitespacesAndNewlines)
            }) else {
                failed += 1
                print("[FAIL] privacy case not found in database")
                continue
            }
            if SensitiveDetector.containsSensitive(stored) {
                passed += 1
            } else {
                failed += 1
                print("[FAIL] privacy case not detected as sensitive: \(text.prefix(40))")
            }
        }

        let total = cases.count + privacyCases.count
        print("Classification Corpus: total=\(total) passed=\(passed) failed=\(failed)")
        try? FileManager.default.removeItem(at: dir)
        return failed == 0 ? 0 : 1
    }
}
