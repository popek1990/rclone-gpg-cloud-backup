# rclone-gpg-cloud-backup
**Version 1.0**

A simple and secure backup script for Linux: **compress → encrypt → upload to the cloud**.  
Uses [rclone](https://rclone.org) + [GPG](https://gnupg.org) to create encrypted archives and send them to your cloud storage (OneDrive, Google Drive, S3, etc).

---

## 🚀 Features

- Compress multiple folders/files into one archive  
- Encrypt the archive with **GPG (public key)**  
- Upload encrypted archive to any **rclone remote**  
- Automatic cleanup of old backups (local + remote)  
- Beginner-friendly and cron-ready  
- Colorful logs and optional ASCII banner  

---

## 🖥️ Requirements

- Linux with bash  
- GPG (recipient public key required)  
- [rclone](https://rclone.org) configured  
- tar, zstd or pigz/gzip   

➡️ Full list is in [`requiraments`](./requiraments)

---

## 📝 Quick-Start Guide

### 1. Clone this repo to your server
```bash
git clone https://github.com/popek1990/rclone-gpg-cloud-backup.git
cd rclone-gpg-cloud-backup
```

### 2. Make files executable
2. Make files executable
Before running the script, make sure it has execute permissions:
```bash
sudo chmod +x rclone-gpg-cloud-backup.sh requiraments
```

**Install required packages**

Install all system dependencies automatically from the included list:

```bash
sudo apt update
xargs -a requiraments sudo apt install -y
```

If rclone was not installed or is outdated, use the official installer:

`curl https://rclone.org/install.sh | sudo bash`

### 4. Create starter config
```bash
./rclone-gpg-cloud-backup.sh --init-config
```

This command will create the file (in this folder):
```bash
rclone-gpg-cloud-backup/
```

Open this file in your text editor (for example `nano`) and set:
- `BACKUP_ITEMS` — which folders/files to back up  
- `GPG_RECIPIENT_FPR` — your GPG public key fingerprint  
- `REMOTE_NAME` — rclone remote name (e.g. onedrive, gdrive, s3)  
- `REMOTE_DIR` — base folder on cloud storage  

---

### 3. Configure rclone (if not yet done)
Make sure your rclone remote is working:

```bash
rclone config
```

You can test access to your remote with (example for OneDrive):
```bash
rclone lsd onedrive:
```

---

### 4. Test run (no upload)
Run a full compression and encryption test without sending files to the cloud:
```bash
./rclone-gpg-cloud-backup.sh --dry-run
```

If everything works correctly, you will see messages similar to:
```text
✅ Dependencies OK.
✅ Encrypted: /path/to/archive.tar.zst.gpg
🚧 Dry-run: upload skipped
```

---

### 5. Run full backup
To create and upload an encrypted backup:
```bash
./rclone-gpg-cloud-backup.sh
```

This will:
1. Compress all items listed in `BACKUP_ITEMS`  
2. Encrypt the archive with your GPG key  
3. Upload the `.gpg` file to your rclone cloud remote  
4. Clean up old backups automatically (based on retention)

---

### 6. Add to CRON (optional)
To automate daily backups at 02:00, add this line to your crontab:
```cron
0 2 * * * /path/to/rclone-gpg-cloud-backup.sh >> /var/log/rclone-gpg-cloud-backup.log 2>&1
```

Check your cron logs to confirm it’s running correctly.

---

## 🖼️ How It Works

1. Collects all paths from `BACKUP_ITEMS`  
2. Creates a compressed archive (`.tar.zst` or `.tar.gz`)  
3. Encrypts it with your **GPG public key** → `.gpg`  
4. Uploads to:
   ```
   REMOTE_NAME:REMOTE_DIR/LABEL/HOST_TAG/YYYY-MM-DD/
   ```
5. Deletes old archives (based on retention settings)

---

## ⚙️ Configuration Example

Edit your local config file `./.rclone.conf` with values similar to:

```bash
BACKUP_ITEMS=( "/etc" "$HOME/projects" )
BACKUP_ROOT="$HOME/cloud-backup"
LABEL="myserver"
HOST_TAG="$(hostname -s)"
COMPRESSION="zstd"

GPG_RECIPIENT_FPR="9KASPA3681F2041TAODB3ACNEPTUNE54124D1A"
GPG_IMPORT_KEY_FILE=""

REMOTE_NAME="onedrive"
REMOTE_DIR="Backups"

LOCAL_RETENTION_DAYS="30"
REMOTE_RETENTION_DAYS="45"
```

---

## 🧠 Tips

- Quick health check (deps + config + GPG + rclone):
  ```bash
  ./rclone-gpg-cloud-backup.sh --check
  ```
- Skip cleanup (keep all backups):
  ```bash
  ./rclone-gpg-cloud-backup.sh --no-retain
  ```
- Logs are stored under:
  ```
  $BACKUP_ROOT/YYYY-MM-DD/<label>_cloud_backup_<timestamp>.log
  ```

---

## 🔐 Security Notes

- Always **verify your GPG key fingerprint** before placing it in the config file.  
- Import a public key manually if needed:
  ```bash
  gpg --import /path/to/public_key.asc
  ```
- List available keys:
  ```bash
  gpg --list-keys
  ```

---

## 💬 Support & Contributions

If you find this project useful — star ⭐ it on GitHub and share it.  
Pull requests with small improvements (e.g., better logging or new cloud examples) are welcome.

---

## 📜 Changelog

**Version 1.0**  
- Initial release: compression, encryption, upload + retention  
- Separate config file (./.rclone.conf) and cron support  
- Beginner-friendly and portable
