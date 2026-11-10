import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export type ThemeMode = 'system' | 'light' | 'dark';

export interface ThemePalette {
  background: string;
  text: string;
  secondaryText: string;
  mutedText: string;
  input: string;
  secondaryButton: string;
  selectedRow: string;
  border: string;
  accent: string;
  inactive: string;
  disconnect: string;
  danger: string;
  onAccent: string;
}

export const LIGHT_THEME: ThemePalette = {
  background: '#F7FAF8', text: '#182A23', secondaryText: '#52635D', mutedText: '#78877F',
  input: '#EDF2EE', secondaryButton: '#E7EDE9', selectedRow: '#EDF6F1', border: '#E0E7E2',
  accent: '#147D59', inactive: '#91A199', disconnect: '#34483D', danger: '#B42318', onAccent: '#FFFFFF'
};

export const DARK_THEME: ThemePalette = {
  background: '#101714', text: '#F1F6F3', secondaryText: '#B8C5BE', mutedText: '#8C9A92',
  input: '#202C27', secondaryButton: '#26332D', selectedRow: '#1D352C', border: '#2D3B34',
  accent: '#3DBA86', inactive: '#718078', disconnect: '#52675D', danger: '#FF8A82', onAccent: '#101714'
};

export function normalizeTheme(value: string): ThemeMode {
  return value === 'light' || value === 'dark' ? value : 'system';
}

export function resolveTheme(mode: ThemeMode, colorMode: ConfigurationConstant.ColorMode | undefined): 'light' | 'dark' {
  if (mode !== 'system') {
    return mode;
  }
  return colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 'dark' : 'light';
}

export class ThemeStore {
  static async mode(context: common.Context): Promise<ThemeMode> {
    const store = await preferences.getPreferences(context, { name: 'socks5_theme' });
    return normalizeTheme(await store.get('mode', 'system') as string);
  }

  static apply(context: common.Context, mode: ThemeMode): void {
    const colorMode = mode === 'system' ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET :
      (mode === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    context.getApplicationContext().setColorMode(colorMode);
  }

  static async save(context: common.Context, mode: ThemeMode): Promise<void> {
    const store = await preferences.getPreferences(context, { name: 'socks5_theme' });
    await store.put('mode', mode);
    await store.flush();
    ThemeStore.apply(context, mode);
  }
}