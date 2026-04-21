# Plot Oracle

Plot Protocol — blockchain-based truth verification system on Base L2.

## PM2 Services

| Port | Name | Type |
|------|------|------|
| 3000 | plot-oracle-3000 | Node.js / Express API (TypeScript) |
| 8000 | plot-oracle-8000 | Python / FastAPI (SNS + CVS) |
| 42069 | plot-oracle-42069 | Ponder indexer |

**PM2 binary:** `~/.local/bin/pm2`

**Terminal Commands:**
```bash
~/.local/bin/pm2 start ecosystem.config.cjs   # First time
~/.local/bin/pm2 start all                    # After first time
~/.local/bin/pm2 stop all / ~/.local/bin/pm2 restart all
~/.local/bin/pm2 start plot-oracle-3000 / ~/.local/bin/pm2 stop plot-oracle-3000
~/.local/bin/pm2 logs / ~/.local/bin/pm2 status / ~/.local/bin/pm2 monit
~/.local/bin/pm2 save                         # Save process list
~/.local/bin/pm2 resurrect                    # Restore saved list
```
