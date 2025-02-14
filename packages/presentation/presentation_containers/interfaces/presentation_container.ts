/*
 * Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
 * or more contributor license agreements. Licensed under the Elastic License
 * 2.0 and the Server Side Public License, v 1; you may not use this file except
 * in compliance with, at your election, the Elastic License 2.0 or the Server
 * Side Public License, v 1.
 */

import {
  apiHasParentApi,
  apiHasUniqueId,
  PublishesViewMode,
  PublishingSubject,
} from '@kbn/presentation-publishing';
import { apiCanAddNewPanel, CanAddNewPanel } from './can_add_new_panel';
import { PublishesSettings } from './publishes_settings';

export interface PanelPackage<SerializedState extends object = object> {
  panelType: string;
  initialState?: SerializedState;
}

export interface PresentationContainer
  extends Partial<PublishesViewMode & PublishesSettings>,
    CanAddNewPanel {
  /**
   * Removes a panel from the container.
   */
  removePanel: (panelId: string) => void;

  /**
   * Determines whether or not a container is capable of removing panels.
   */
  canRemovePanels?: () => boolean;

  /**
   * Replaces a panel in the container with a new panel.
   */
  replacePanel: <SerializedState extends object = object>(
    idToRemove: string,
    newPanel: PanelPackage<SerializedState>
  ) => Promise<string>;

  /**
   * Returns the number of panels in the container.
   */
  getPanelCount: () => number;

  /**
   * A publishing subject containing the child APIs of the container. Note that
   * children are created asynchronously. This means that the children$ observable might
   * contain fewer children than the actual number of panels in the container.
   */
  children$: PublishingSubject<{ [key: string]: unknown }>;
}

export const apiIsPresentationContainer = (api: unknown | null): api is PresentationContainer => {
  return Boolean(
    apiCanAddNewPanel(api) &&
      typeof (api as PresentationContainer)?.removePanel === 'function' &&
      typeof (api as PresentationContainer)?.replacePanel === 'function' &&
      typeof (api as PresentationContainer)?.addNewPanel === 'function' &&
      (api as PresentationContainer)?.children$
  );
};

export const getContainerParentFromAPI = (
  api: null | unknown
): PresentationContainer | undefined => {
  const apiParent = apiHasParentApi(api) ? api.parentApi : null;
  if (!apiParent) return undefined;
  return apiIsPresentationContainer(apiParent) ? apiParent : undefined;
};

export const listenForCompatibleApi = <ApiType extends unknown>(
  parent: unknown,
  isCompatible: (api: unknown) => api is ApiType,
  apiFound: (api: ApiType | undefined) => (() => void) | void
) => {
  if (!parent || !apiIsPresentationContainer(parent)) return () => {};

  let lastCleanupFunction: (() => void) | undefined;
  let lastCompatibleUuid: string | null;
  const subscription = parent.children$.subscribe((children) => {
    lastCleanupFunction?.();
    const compatibleApi = (() => {
      for (const childId of Object.keys(children)) {
        const child = children[childId];
        if (isCompatible(child)) return child;
      }
      if (isCompatible(parent)) return parent;
      return undefined;
    })();
    const nextId = apiHasUniqueId(compatibleApi) ? compatibleApi.uuid : null;
    if (nextId === lastCompatibleUuid) return;
    lastCompatibleUuid = nextId;
    lastCleanupFunction = apiFound(compatibleApi) ?? undefined;
  });
  return () => {
    subscription.unsubscribe();
    lastCleanupFunction?.();
  };
};
