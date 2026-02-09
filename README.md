
# GlyNet Shell (gsh)

GlyNet Shell (gsh) is a lightweight terminal tool designed to simplify SSH management across multiple servers, especially when using firewall restrictions and jump servers.

The idea started when I deployed **CSF firewall** on all servers and restricted SSH access to specific trusted IP ranges.
Since I connect from multiple platforms and most free SSH managers don’t properly sync configurations, I built **gsh**.

gsh helps you centralize SSH management through a single intermediary server (jump server / bastion host model).

---

## ✨ Features

* Simple SSH host management (add / update / remove)
* Auto SSH config management
* Optional hostname → fresh IP resolving before connect (useful for DNS/CDN / Anycast)
* Secure backup of:

  * `~/.ssh`
  * `~/bin`
* Encrypted ZIP backups
* Optional Telegram backup upload
* Designed for jump server workflows
* Zero database / zero daemon — pure bash

---

## 📦 Installation

### One-Line Install (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/s7net/GlyNet-Shell/refs/heads/main/install-gsh.sh | bash
```

or

```bash
wget -qO- https://raw.githubusercontent.com/s7net/GlyNet-Shell/refs/heads/main/install-gsh.sh | bash
```

---

### What Installer Does

If you are **root**:

```
/usr/local/bin/gsh
```

If you are **normal user**:

```
~/bin/gsh
```

Also installs:

```
~/.ssh/.gsh.env
```

---

## ⚙️ Configuration

Main config file:

```
~/.ssh/.gsh.env
```

You can edit values manually or run:

```bash
gsh init
```

---

## 🚀 Usage

### Add New Server

```bash
gsh add server-name
```

---

### Connect to Server

```bash
gsh server-name
```

---

### Update Server

```bash
gsh update server-name
```

---

### Remove Server

```bash
gsh rm server-name
```

---

### List Servers

```bash
gsh ls
```

---

### Sort SSH Config

```bash
gsh sort
```

---

## 💾 Backup & Restore

### Create Backup

```bash
gsh backup
```

Creates encrypted backup of:

* SSH keys
* SSH config
* gsh config
* bin tools

---

### Restore Backup

```bash
gsh restore backup.zip
```

---

## 🔐 Security Notes

* `.gsh.env` stored with `chmod 600`
* `.ssh` enforced as `700`
* Backup ZIP supports password encryption
* No telemetry
* No background services

---

## 🧠 Recommended Use Case

Perfect for:

* Jump server environments
* Bastion SSH architectures
* Teams managing multiple nodes
* Users with restricted firewall SSH access
* DevOps / Infra engineers

---

## 🛠 Requirements

Usually preinstalled on most Linux systems:

* bash
* ssh
* curl or wget
* zip or 7z (for backup)

---

## 📁 Project Files

Main binary:

```
gsh
```

Default config template:

```
.gsh.env
```

Installer:

```
install-gsh.sh
```

---

## ❤️ Why gsh Exists

Because SSH management should be:

* Simple
* Syncable
* Scriptable
* Portable
* Secure
