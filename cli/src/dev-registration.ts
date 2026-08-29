import { pathsEqual, type Registration, type RegistryDocument } from "./host-tools.js";

export function endDevRegistration(
  current: RegistryDocument,
  name: string,
  directory: string,
  prior: Registration | undefined,
  write: (document: RegistryDocument) => void,
  reload: () => void,
): RegistryDocument | undefined {
  const registration = current.widgets.find((widget) => widget.name === name);
  if (!registration?.dev || !pathsEqual(registration.sourcePath, directory)) return undefined;

  const widgets = current.widgets.filter((widget) => widget.name !== name);
  if (prior && !prior.dev) widgets.push(prior);
  const next = { widgets };
  write(next);
  // Dev has ended, so this registry remains authoritative even when the
  // running host cannot acknowledge its reload notification.
  reload();
  return next;
}
