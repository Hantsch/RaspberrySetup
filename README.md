# Basic Setup

```shell
curl -fsSL https://raw.githubusercontent.com/Hantsch/RaspberrySetup/main/basic_develop.sh | bash
```

# Git Connection

### Generate a dedicated key:

```bash
ssh-keygen -t ed25519 -C "rpi-deploy-key"
```

Press Enter for:

file location (default is fine)

NO passphrase (important for automation)
It creates:

```code
~/.ssh/id_ed25519
~/.ssh/id_ed25519.pub
```

### Copy Public Key

```bash
cat ~/.ssh/id_ed25519.pub
```

### Add as Deploy Key in GitHub

Go to your repository →
Settings → Deploy keys → Add deploy key

Add:

- Title: Raspberry Pi

- Paste the public key

- ✅ Allow write access (if needed)

### Test Connection

On the Pi:

```bash
ssh -T git@github.com
```

You should see:

```code
Hi username! You've successfully authenticated...
```
