# GitHub Organization Full Backup to Azure Blob Storage

GitHub Organization 内のすべてのリソースを Azure Blob Storage に定期バックアップします。

## バックアップ対象 (15種類)

| # | 対象 | 内容 |
|---|------|------|
| 1 | **Repositories** | 全リポジトリの mirror clone (全ブランチ・タグ・LFS含む) |
| 2 | **Wikis** | Wiki が有効な全リポジトリの Wiki |
| 3 | **Projects (v2)** | Organization レベルの GitHub Projects (フィールド・アイテム含む) |
| 4 | **Artifacts** | 期限内の GitHub Actions Artifacts |
| 5 | **Releases & Assets** | 全リリースメタデータ + バイナリアセット |
| 6 | **Packages** | npm, Maven, NuGet, RubyGems, Container (メタデータ + Dockerイメージ) |
| 7 | **Issues & Pull Requests** | 全Issue/PR (コメント, レビュー, ラベル, マイルストーン含む) |
| 8 | **Discussions** | 全リポのディスカッション (回答, コメント, リプライ含む) |
| 9 | **Workflow Logs** | 直近のワークフロー実行ログ (各リポ最新10件) |
| 10 | **Actions Config** | Org/Repo/Environment レベルの変数 + シークレット名一覧 |
| 11 | **Security Alerts** | Dependabot, Code Scanning, Secret Scanning アラート |
| 12 | **Teams & Memberships** | チーム構成, メンバー, 外部コラボレーター, リポ権限 |
| 13 | **Webhooks** | Org + Repo レベルの Webhook 設定 |
| 14 | **Branch Protections & Rulesets** | ブランチ保護ルール + Org/Repo レベルのルールセット |
| 15 | **Custom Properties** | リポジトリのカスタムプロパティ (スキーマ + 値) |

> **Note**: Actions Secrets の **値** は GitHub API のセキュリティ制約により取得不可です。名前一覧のみバックアップされます。

## セットアップ

### 1. Azure リソースの準備

```bash
# Storage Account 作成
az storage account create \
  --name <YOUR_STORAGE_ACCOUNT> \
  --resource-group <YOUR_RESOURCE_GROUP> \
  --location <YOUR_LOCATION> \
  --sku Standard_LRS

# Container 作成
az storage container create \
  --account-name <YOUR_STORAGE_ACCOUNT> \
  --name <YOUR_CONTAINER_NAME>
```

### 2. GitHub App の作成

GitHub Organization に GitHub App を作成してインストールします。

#### GitHub App の作成手順

1. **Organization Settings** → **Developer settings** → **GitHub Apps** → **New GitHub App**
2. 以下を設定:
   - **GitHub App name**: `org-backup` (任意)
   - **Homepage URL**: リポジトリの URL
   - **Webhook**: Active のチェックを **外す** (不要)
3. パーミッションを設定 (下表参照)
4. **Where can this GitHub App be installed?** → **Only on this account**
5. 作成後、**App ID** をメモ
6. **Generate a private key** でプライベートキーをダウンロード (.pem)
7. **Install App** → 対象 Organization にインストール → **All repositories** を選択

#### 必要なパーミッション

**Repository permissions:**

| Permission | Access | 用途 |
|-----------|--------|------|
| Actions | Read | Artifacts, Workflow logs, Variables, Environments |
| Administration | Read | Branch protections, Rulesets |
| Contents | Read | Repo clone, Wikis, Releases |
| Environments | Read | Environment variables, secret names |
| Issues | Read | Issues, Labels, Milestones |
| Metadata | Read | リポジトリ一覧 (自動付与) |
| Pull requests | Read | PR, Reviews, Review comments |
| Secrets | Read | Secret names (値は取得不可) |
| Variables | Read | Repo/Env variables |
| Webhooks | Read | Repo level webhooks |
| Code scanning alerts | Read | Code scanning alerts |
| Dependabot alerts | Read | Dependabot alerts |
| Secret scanning alerts | Read | Secret scanning alerts |

**Organization permissions:**

| Permission | Access | 用途 |
|-----------|--------|------|
| Administration | Read | Org rulesets |
| Custom properties | Read | Custom property schema & values |
| Members | Read | Teams, Memberships, Collaborators |
| Projects | Read | GitHub Projects v2 |
| Secrets | Read | Org secret names |
| Variables | Read | Org variables |
| Webhooks | Read | Org webhooks |

### 3. GitHub Secrets の設定

以下の Secrets をリポジトリに設定してください:

| Secret 名 | 説明 |
|-----------|------|
| `GITHUB_APP_ID` | GitHub App の App ID |
| `GITHUB_APP_PRIVATE_KEY` | GitHub App のプライベートキー (.pem ファイルの中身) |
| `AZURE_CREDENTIALS` | Azure Service Principal の JSON 認証情報 |
| `AZURE_STORAGE_SAS_TOKEN` | (任意) Azure Storage SAS トークン。未設定の場合は `az login` を使用 |

#### Azure Service Principal の作成

```bash
az ad sp create-for-rbac \
  --name "github-backup-sp" \
  --role "Storage Blob Data Contributor" \
  --scopes /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.Storage/storageAccounts/<STORAGE_ACCOUNT> \
  --sdk-auth
```

出力された JSON を `AZURE_CREDENTIALS` Secret に設定します。

### 4. ワークフロー設定の更新

`.github/workflows/backup.yml` 内のプレースホルダーを置換:

```yaml
env:
  GITHUB_ORG: '<YOUR_GITHUB_ORG>'              # ← Organization 名
  AZURE_STORAGE_ACCOUNT: '<YOUR_STORAGE_ACCOUNT>'
  AZURE_STORAGE_CONTAINER: '<YOUR_CONTAINER_NAME>'
```

## 実行

### 自動実行

毎日 UTC 02:00 に自動実行されます (cron: `0 2 * * *`)。

### 手動実行

GitHub Actions → "GitHub Organization Backup" → "Run workflow" から手動実行できます。
並列ジョブ数はパラメータで変更可能（デフォルト: 4）。

## Blob ストレージの構造

```
backups/
  └── 20260417T020000Z/
      ├── manifest.json
      ├── repos/
      │   └── *.tar.gz
      ├── wikis/
      │   └── *-wiki.tar.gz
      ├── projects/
      │   └── project-*.json
      ├── artifacts/
      │   └── <repo>/*.zip
      ├── releases/
      │   └── <repo>/
      │       ├── releases.json
      │       └── <tag>/<asset-file>
      ├── packages/
      │   └── <type>/<name>/
      │       ├── metadata.json
      │       ├── versions.json
      │       └── image-latest.tar.gz  (container only)
      ├── issues/
      │   └── <repo>/
      │       ├── issues.json
      │       ├── labels.json
      │       ├── milestones.json
      │       └── comments/
      ├── discussions/
      │   └── <repo>/discussions.json
      ├── workflow-logs/
      │   └── <repo>/
      │       ├── runs.json
      │       └── *.zip
      ├── actions-config/
      │   ├── org-variables.json
      │   ├── org-secret-names.json
      │   └── <repo>/
      │       ├── variables.json
      │       ├── secret-names.json
      │       └── environments.json
      ├── security/
      │   └── <repo>/
      │       ├── dependabot-alerts.json
      │       ├── code-scanning-alerts.json
      │       └── secret-scanning-alerts.json
      ├── teams/
      │   ├── org-members.json
      │   ├── outside-collaborators.json
      │   ├── teams.json
      │   └── <team-slug>/
      │       ├── members.json
      │       └── repos.json
      ├── webhooks/
      │   ├── org-webhooks.json
      │   └── <repo>-webhooks.json
      ├── protection-rules/
      │   ├── org-rulesets.json
      │   ├── org-ruleset-*.json
      │   └── <repo>/
      │       ├── branch-*-protection.json
      │       └── rulesets.json
      └── custom-properties/
          ├── org-property-schema.json
          └── repo-property-values.json
```

## 保持期間

バックアップの保持・削除は Azure Blob Storage のライフサイクル管理ポリシーで制御してください。

```bash
# 例: 90日経過で Cool 層に移動、365日経過で削除するポリシー
az storage account management-policy create \
  --account-name <YOUR_STORAGE_ACCOUNT> \
  --policy @- <<'EOF'
{
  "rules": [
    {
      "name": "backup-lifecycle",
      "type": "Lifecycle",
      "definition": {
        "filters": {
          "blobTypes": ["blockBlob"],
          "prefixMatch": ["backups/"]
        },
        "actions": {
          "baseBlob": {
            "tierToCool": { "daysAfterModificationGreaterThan": 90 },
            "delete": { "daysAfterModificationGreaterThan": 365 }
          }
        }
      }
    }
  ]
}
EOF
```

## ローカル実行

```bash
# Option A: GitHub App 認証 (推奨)
export GITHUB_ORG="your-org"
export GITHUB_APP_ID="123456"
export GITHUB_APP_PRIVATE_KEY_FILE="/path/to/your-app.pem"
export AZURE_STORAGE_ACCOUNT="yourstorageaccount"
export AZURE_STORAGE_CONTAINER="backups"
export AZURE_STORAGE_SAS_TOKEN="sv=2022-..."  # optional
export PARALLEL_JOBS=4                         # optional

bash scripts/backup.sh

# Option B: 事前生成済みトークンを使用
export GITHUB_ORG="your-org"
export GITHUB_TOKEN="ghs_xxxx"   # installation access token
export AZURE_STORAGE_ACCOUNT="yourstorageaccount"
export AZURE_STORAGE_CONTAINER="backups"

bash scripts/backup.sh
```

## 依存ツール

| ツール | 用途 | 必須 |
|--------|------|------|
| `bash` | スクリプト実行 | ✓ |
| `curl` | GitHub API 呼び出し | ✓ |
| `jq` | JSON パース | ✓ |
| `git` | リポジトリ/Wiki クローン | ✓ |
| `az` (Azure CLI) | Blob アップロード | ✓ |
| `openssl` | GitHub App JWT 署名 (ローカル実行時) | △ (GitHub Actions では不要) |
| `git-lfs` | LFS オブジェクト取得 | △ (なくてもスキップ) |
| `docker` | コンテナイメージ保存 | △ (なくてもスキップ) |
