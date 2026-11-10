import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const BUNDLE_NAME: string = 'org.ohos.rfc';
export const VPN_ABILITY: string = 'VpnExtAbility';

export interface ServerConfig {
  host: string;
  port: number;
}

export interface ConnectionState {
  phase: string;
  message: string;
  updatedAt: number;
}

export function appendDiagnosticLog(context: common.Context, message: string): void {
  hilog.info(0x3200, 'socks5vpn', '%{public}s', message);
  try {
    const path = `${context.getApplicationContext().filesDir}/vpn.log`;
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.APPEND);
    try {
      fs.writeSync(file.fd, `${new Date().toISOString()} ${message}\n`);
    } finally {
      fs.closeSync(file);
    }
  } catch (_) {
  }
}

export function readDiagnosticLog(context: common.Context): string {
  const sections: string[] = [];
  for (const name of ['vpn.log', 'tun2socks.log']) {
    try {
      const path = `${context.getApplicationContext().filesDir}/${name}`;
      const size = fs.statSync(path).size;
      const offset = Math.max(0, size - 32768);
      const content = fs.readTextSync(path, { offset: offset, length: Math.min(size, 32768) });
      sections.push(`--- ${name} ---\n${content.split('\n').slice(-160).join('\n')}`);
    } catch (error) {
      sections.push(`--- ${name} ---\n${JSON.stringify(error)}`);
    }
  }
  return sections.join('\n\n');
}

export function validateServer(host: string, port: string): string {
  if (/[^\x00-\x7F]/.test(host)) {
    return '服务器地址含有非英文字符。IP 请使用英文句点 .，例如 192.168.3.13';
  }
  if (!host.trim() || /[\s\/@\\\x00:\[\]]/.test(host)) {
    return '请输入服务器 IPv4 地址或域名，不包含协议前缀';
  }
  if (!/^\d+$/.test(port) || Number(port) < 1 || Number(port) > 65535) {
    return '端口范围为 1 到 65535';
  }
  return '';
}

export async function loadServer(context: common.Context): Promise<ServerConfig> {
  const store = await preferences.getPreferences(context, { name: 'socks5' });
  return { host: await store.get('host', '') as string, port: await store.get('port', 1080) as number };
}

export async function saveServer(context: common.Context, config: ServerConfig): Promise<void> {
  const store = await preferences.getPreferences(context, { name: 'socks5' });
  await store.put('host', config.host);
  await store.put('port', config.port);
  await store.flush();
}

export function writeState(context: common.Context, phase: string, message: string = ''): void {
  const state: ConnectionState = { phase: phase, message: message, updatedAt: Date.now() };
  const path = `${context.getApplicationContext().filesDir}/vpn-state.json`;
  const file = fs.openSync(`${path}.tmp`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(file.fd, JSON.stringify(state));
  } finally {
    fs.closeSync(file);
  }
  fs.renameSync(`${path}.tmp`, path);
}

export function readState(context: common.Context): ConnectionState {
  try {
    const state = JSON.parse(fs.readTextSync(`${context.getApplicationContext().filesDir}/vpn-state.json`)) as ConnectionState;
    if (state.phase === 'failed' || Date.now() - state.updatedAt < 5000) {
      return state;
    }
  } catch (_) {
  }
  return { phase: 'disconnected', message: '', updatedAt: 0 };
}