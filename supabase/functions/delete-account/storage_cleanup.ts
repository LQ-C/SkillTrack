export const resourceCleanupBuckets = ["mentor-reading-files", "mentor-video-files", "task-attachments"] as const;
type StorageError = {statusCode?: string | number};
export interface OwnedStorage {
  list(prefix: string, options: {limit: number; offset: number}): Promise<{
    data: {name: string; id?: string | null}[] | null; error: StorageError | null}>;
  remove(paths: string[]): Promise<{error: StorageError | null}>;
}
// UUID-bound prefix traversal. Called only after account password reauthentication.
export async function clearOwnedFolder(store: OwnedStorage, owner: string,
  prefix = owner, depth = 0): Promise<void> {
  if (!/^[0-9a-f-]{36}$/i.test(owner) || depth > 12 ||
      !(prefix === owner || prefix.startsWith(`${owner}/`))) {
    throw new Error('Invalid cleanup path');
  }
  while (true) {
    const {data, error} = await store.list(prefix, {limit: 100, offset: 0});
    if (error) {
      if (String(error.statusCode) === '404') return;
      throw new Error('Storage cleanup unavailable');
    }
    if (!data?.length) return;
    const objects: string[] = [];
    for (const item of data) {
      if (!item.name || item.name.includes('/') || item.name === '.' || item.name === '..') {
        throw new Error('Invalid cleanup object');
      }
      const path = `${prefix}/${item.name}`;
      if (item.id == null) await clearOwnedFolder(store, owner, path, depth + 1);
      else objects.push(path);
    }
    if (objects.length) {
      const {error: removeError} = await store.remove(objects);
      if (removeError) throw new Error('Storage cleanup unavailable');
    }
  }
}
