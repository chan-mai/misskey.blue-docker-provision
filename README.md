# misskey.blue-docker-provision
misskey.blueと関連サーバをいい感じに構築/運用するためのレポジトリ  
サーバ構築はAnsible、デプロイは[doco-cd](https://github.com/kimdre/doco-cd)、秘密ファイルは[sops](https://github.com/getsops/sops)で暗号化してこのレポジトリで管理しています。  

## 構成
ホストごとのスタックを`hosts/`配下で管理する。各ホストのdoco-cdはpoll設定の`target`に対応するルート直下の`.doco-cd.<target>.yaml`をデプロイする。

| パス | 内容 |
|---|---|
| `hosts/misskey-blue/` | 本体。proxy(Caddy), maintenance, app(misskey-tempura), redis, db(PGroonga), backup(misskey-backup)。`.config/`にMisskey, Caddy, backupの設定、hotpatchスクリプトもここに置く |
| `hosts/media-proxy/` | メディアプロキシ。proxy(Caddy), media-proxy([media-proxy-rs](https://github.com/nyaone/media-proxy-rs))。`media-proxy.misskey.blue`として公開し、misskey.blue以外のインスタンスからも参照する |
| `shared/` | ホスト間で共有するCloudflare Origin証明書(`certificate.pem`, `key.pem`) |
| `.doco-cd.<target>.yaml` | doco-cdのデプロイ設定(ホストごと)。`.doco-cd.yaml`は本体ホストのpoll切替完了までの暫定 |
| `doco-cd/` | doco-cd本体のcompose.yamlとポーリング設定テンプレート(Ansibleがサーバの`/home/ubuntu/doco-cd`へ配置) |
| `ansible/` | サーバ構築(`setup.yml`)とサーバ移行(`migrate.yml`)。共通変数は`group_vars/all.yml`、ホスト固有値は`host_vars/<host>.yml` |
| `.github/workflows/` | イメージ更新のPRを自動作成 |

データは名前付きvolumeに保存される。
- misskey-blue: `misskeyblue-docker-provision_` + `pg-18`, `redis`, `caddy-data`, `caddy-config`, `caddy-logs`, `mi-backups`
- media-proxy: `media-proxy_` + `caddy-data`, `caddy-config`, `caddy-logs`(永続データなし。Ansibleでの事前作成も不要)

## ローカルに必要なツール
- sops, age
- Ansibleと必要なcollection
  ```bash
  ansible-galaxy collection install -r ansible/requirements.yml
  ```

## 秘密ファイル
`.sops.yaml`にパスごとの受信者(age公開鍵)を列挙している。

| ファイル | 内容 | 復号可能な鍵 |
|---|---|---|
| `hosts/misskey-blue/.config/.env` | DBとbackupの環境変数 | misskey-blue, ローカル |
| `hosts/misskey-blue/.config/default.yml` | Misskeyの設定 | misskey-blue, ローカル |
| `shared/key.pem` | Cloudflare Origin Certificateの秘密鍵 | misskey-blue, media-proxy, ローカル |
| `ansible/vars/secrets.sops.yml` | Ansibleがサーバへ配置する値(下表) | ローカル |

| `secrets.sops.yml`のキー | 内容 |
|---|---|
| `doco_cd_age_keys` | サーバ用age秘密鍵ファイルの内容(inventoryのホスト名をキーにした辞書) |
| `apprise_notify_urls` | デプロイ通知先の[Apprise URL](https://github.com/caronc/apprise/wiki)(e.x. `discord://<webhook_id>/<webhook_token>/`) |
| `admin_user_password_hash` | 管理ユーザ(`group_vars/all.yml`の`admin_user`)のパスワードハッシュ(`openssl passwd -6`で生成) |
| `tailscale_auth_key` | Tailscaleの認証キー(管理コンソールで発行) |

編集はローカル鍵がある環境で行う。  
```bash
sops edit hosts/misskey-blue/.config/.env
sops edit ansible/vars/secrets.sops.yml
```
  
鍵を作り直す場合は`age-keygen`で鍵対を生成し、公開鍵を`.sops.yaml`へ設定した上で`sops updatekeys <file>`で各ファイルを再暗号化すること。  

## サーバ構築
```bash
cd ansible
cp inventory.yml.sample inventory.yml
ansible-playbook setup.yml --limit <host>
ansible-playbook setup.yml --limit <host> --tags start
```

`setup.yml`は`servers`グループの各ホストへ、ホスト名(`host_vars/<host>.yml`の`server_hostname`), TZ, Docker, 永続データボリューム(`data_volumes`), 管理ユーザ(sudo, dockerグループ, `admin_user_ssh_keys`の公開鍵)を設定し、doco-cd一式を配置した後、Tailscale(tailnetへ参加, Tailscale SSH有効)とufwを設定する。`misskey-postgres`ネットワークは`create_misskey_postgres_network: true`のホストのみ作成する。  
ufwはSSHを`ufw_ssh_allow_from`(既定はtailnetの`100.64.0.0/10`)からのみ許可し、TailscaleのUDP 41641以外の受信を拒否する。Dockerが公開するポート(80, 443)はufwを経由しない。  
ufw有効化後は公開IPでSSHできなくなるため、以降の`ansible-playbook`実行前に`inventory.yml`の該当ホストの`ansible_host`をTailscaleのアドレス(またはMagicDNS名)へ変更すること。  
移行時はデータ投入前にdoco-cdが起動しないようにするため、doco-cdの起動は`--tags start`で行うこと。  

起動後、doco-cdは配置されたpoll設定(`doco-cd/poll.yaml.j2`から生成, `target`は`host_vars`の`doco_cd_target`)の間隔でこのレポジトリのmainを取得し、クレデンシャルを復号して`.doco-cd.<target>.yaml`の内容をデプロイする。  

`migrate.yml`を実行する場合は、inventoryへ`new`/`old`エイリアス(両方に`compose_project`を定義)を追加し、最終同期は`-e final=true`を付けて実行する。  


## 更新
- mainへマージすると各ホストのdoco-cdが自ホスト分を反映する。イメージ更新は`.github/workflows`がPRを作成する。結果はApprise経由で通知される
- 秘密ファイルの変更は`sops edit`で編集してpushする
- 暗号化ファイルを含むため、通常のcheckoutで`docker compose up`は動作しない。doco-cd経由でデプロイするか、`sops decrypt`で復号してから実行する
- appコンテナの停止中はCaddyがメンテナンスページを表示する
