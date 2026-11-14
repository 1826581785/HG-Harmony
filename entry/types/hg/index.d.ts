/** NAPI 暴露的函数（napi-rs 自动把 snake_case 转 camelCase） */
export const hello: () => string;
export const hgVersion: () => string;
export const hgInit: (dataDir: string) => string;
export const hgBoot: () => Promise<string>;
export const hgLogin: (username: string, password: string) => Promise<string>;
export const hgRegister: (username: string, password: string, email: string) => Promise<string>;
export const hgLogout: () => Promise<string>;
export const hgMe: () => Promise<string>;
export const hgEdge: (method: string, path: string, body?: string | null) => Promise<string>;
export const hgSelftest: () => Promise<string>;
