import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { loadServer, ServerConfig, validateServer } from './SocksConfig';

export interface ServerProfile {
  id: string;
  name: string;
  host: string;
  port: number;
}

export interface ServerSettings {
  servers: ServerProfile[];
  selectedId: string;
}

export function migrateServer(config: ServerConfig): ServerSettings {
  if (!config.host.trim()) {
    return { servers: [], selectedId: '' };
  }
  const server: ServerProfile = {
    id: 'legacy', name: '默认服务器', host: config.host.trim(), port: config.port
  };
  return { servers: [server], selectedId: server.id };
}

export function validateProfile(server: ServerProfile): string {
  if (!server.name.trim()) {
    return '请输入服务器名称';
  }
  return validateServer(server.host, `${server.port}`);
}

export function removeServer(settings: ServerSettings, id: string): ServerSettings {
  const servers = settings.servers.filter((server: ServerProfile) => server.id !== id);
  const selectedId = servers.some((server: ServerProfile) => server.id === settings.selectedId) ?
    settings.selectedId : (servers.length ? servers[0].id : '');
  return { servers: servers, selectedId: selectedId };
}

export class ServerStore {
  static async load(context: common.Context): Promise<ServerSettings> {
    const store = await preferences.getPreferences(context, { name: 'socks5_servers' });
    const saved = await store.get('settings', '') as string;
    if (saved) {
      const settings = JSON.parse(saved) as ServerSettings;
      if (!settings.servers.some((server: ServerProfile) => server.id === settings.selectedId)) {
        settings.selectedId = settings.servers.length ? settings.servers[0].id : '';
      }
      return settings;
    }
    const settings = migrateServer(await loadServer(context));
    await ServerStore.save(context, settings);
    return settings;
  }

  static async save(context: common.Context, settings: ServerSettings): Promise<void> {
    const store = await preferences.getPreferences(context, { name: 'socks5_servers' });
    await store.put('settings', JSON.stringify(settings));
    await store.flush();
  }
}