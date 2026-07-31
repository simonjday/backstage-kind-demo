// packages/backend/src/modules/kubernetesActions.ts
//
// Custom scaffolder action: applies a YAML manifest to the Kubernetes API
// server using the Backstage pod's own in-cluster service account. There is
// no built-in "apply a manifest" action in Backstage core — this is a
// deliberately minimal one for demo purposes (create-if-missing,
// merge-patch-if-present). Not production-hardened: no dry-run, no diffing,
// no support for CRDs beyond what the generic object API already handles.
//
// Requires: yarn --cwd packages/backend add @kubernetes/client-node js-yaml
//           yarn --cwd packages/backend add -D @types/js-yaml
//
// Typing note: this version of @backstage/plugin-scaffolder-node's
// createTemplateAction uses Zod schemas for input/output — `schema.input`
// is a function receiving a zod implementation and returning a
// z.object(...), not a plain JSON-schema literal.

import { createBackendModule } from '@backstage/backend-plugin-api';
import {
  createTemplateAction,
  scaffolderActionsExtensionPoint,
} from '@backstage/plugin-scaffolder-node';
import * as k8s from '@kubernetes/client-node';
import * as yaml from 'js-yaml';

export const kubernetesApplyAction = () =>
  createTemplateAction({
    id: 'kubernetes:apply',
    description:
      'Applies a Kubernetes manifest (YAML) to the cluster the Backstage pod is running in, using its in-cluster service account. Creates the object if it does not exist, otherwise merge-patches it.',
    schema: {
      input: (z: any) =>
        z.object({
          manifest: z.string().describe('YAML manifest to apply'),
        }),
    },
    async handler(ctx: any) {
      const manifest = ctx.input.manifest as string;

      const kc = new k8s.KubeConfig();
      kc.loadFromCluster(); // uses the pod's mounted service account token + CA

      const client = k8s.KubernetesObjectApi.makeApiClient(kc);
      const doc = yaml.load(manifest) as any;

      if (!doc?.kind || !doc?.metadata?.name) {
        throw new Error(
          'Manifest must have at least kind and metadata.name set',
        );
      }

      const ref = `${doc.kind}/${doc.metadata.name}` +
        (doc.metadata.namespace ? ` in ${doc.metadata.namespace}` : ' (cluster-scoped)');

      try {
        await client.read(doc);
        await client.patch(doc);
        ctx.logger.info(`Patched existing ${ref}`);
      } catch (err) {
        ctx.logger.info(`${ref} not found, creating (reason: ${err})`);
        await client.create(doc);
        ctx.logger.info(`Created ${ref}`);
      }
    },
  });

// Profile/zone → manifest logic lives here in plain TypeScript rather than
// as Nunjucks {% if %} branches inside a YAML string — much easier to read,
// safe from block-scalar whitespace issues, and testable in isolation.
const RESOURCE_PROFILES: Record<
  string,
  { reqCpu: string; reqMem: string; limCpu: string; limMem: string; pods: string }
> = {
  small: { reqCpu: '250m', reqMem: '256Mi', limCpu: '500m', limMem: '512Mi', pods: '10' },
  medium: { reqCpu: '1', reqMem: '1Gi', limCpu: '2', limMem: '2Gi', pods: '30' },
  large: { reqCpu: '4', reqMem: '8Gi', limCpu: '8', limMem: '16Gi', pods: '100' },
};

function buildIngressRules(networkZone: string) {
  if (networkZone === 'restricted') return [];
  if (networkZone === 'dmz') {
    return [{ from: [{ namespaceSelector: { matchLabels: { 'network-zone': 'dmz' } } }] }];
  }
  return [{ from: [{ namespaceSelector: {} }] }]; // internal
}

export const kubernetesProvisionAction = () =>
  createTemplateAction({
    id: 'kubernetes:namespace-provision',
    description:
      'Applies a ResourceQuota, LimitRange, and NetworkPolicy to an existing namespace, sized/scoped by resource_profile and network_zone.',
    schema: {
      input: (z: any) =>
        z.object({
          namespace: z.string(),
          resource_profile: z.enum(['small', 'medium', 'large']),
          network_zone: z.enum(['internal', 'dmz', 'restricted']),
        }),
    },
    async handler(ctx: any) {
      const namespace = ctx.input.namespace as string;
      const resource_profile = ctx.input.resource_profile as string;
      const network_zone = ctx.input.network_zone as string;

      const profile = RESOURCE_PROFILES[resource_profile];
      if (!profile) {
        throw new Error(`Unknown resource_profile: ${resource_profile}`);
      }

      const kc = new k8s.KubeConfig();
      kc.loadFromCluster();
      const client = k8s.KubernetesObjectApi.makeApiClient(kc);

      const applyOne = async (doc: any) => {
        const ref = `${doc.kind}/${doc.metadata?.name} in ${namespace}`;
        try {
          await client.read(doc);
          await client.patch(doc);
          ctx.logger.info(`Patched ${ref}`);
        } catch (err) {
          await client.create(doc);
          ctx.logger.info(`Created ${ref}`);
        }
      };

      await applyOne({
        apiVersion: 'v1',
        kind: 'ResourceQuota',
        metadata: { name: 'default-quota', namespace },
        spec: {
          hard: {
            'requests.cpu': profile.reqCpu,
            'requests.memory': profile.reqMem,
            'limits.cpu': profile.limCpu,
            'limits.memory': profile.limMem,
            pods: profile.pods,
          },
        },
      });

      await applyOne({
        apiVersion: 'v1',
        kind: 'LimitRange',
        metadata: { name: 'default-limits', namespace },
        spec: {
          limits: [
            {
              type: 'Container',
              defaultRequest: { cpu: profile.reqCpu, memory: profile.reqMem },
              default: { cpu: profile.limCpu, memory: profile.limMem },
            },
          ],
        },
      });

      await applyOne({
        apiVersion: 'networking.k8s.io/v1',
        kind: 'NetworkPolicy',
        metadata: { name: `zone-${network_zone}`, namespace },
        spec: {
          podSelector: {},
          policyTypes: ['Ingress'],
          ingress: buildIngressRules(network_zone),
        },
      });

      ctx.logger.info(
        `Provisioned ${namespace} with profile=${resource_profile}, zone=${network_zone}`,
      );
    },
  });

export const kubernetesActionsModule = createBackendModule({
  pluginId: 'scaffolder',
  moduleId: 'kubernetes-actions',
  register(reg) {
    reg.registerInit({
      deps: { scaffolder: scaffolderActionsExtensionPoint },
      async init({ scaffolder }) {
        scaffolder.addActions(
          kubernetesApplyAction() as any,
          kubernetesProvisionAction() as any,
        );
      },
    });
  },
});
