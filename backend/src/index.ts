import express from 'express';
import cors from 'cors';
import { env } from './lib/env.js';
import claimsRouter from './routes/claims.js';

const app = express();

app.use(cors());
app.use(express.json({ limit: '1mb' }));

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'plot-oracle-backend', version: '0.1.0' });
});

app.use('/claims', claimsRouter);

app.use((_req, res) => res.status(404).json({ error: 'Not found' }));

app.use((err: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  console.error('[error]', err.message);
  res.status(500).json({ error: err.message });
});

app.listen(env.PORT, () => {
  console.log(`[plot-oracle-backend] listening on http://localhost:${env.PORT}`);
});
