import { IdentityProfiles } from '../../components/identity-profiles';
import { runtimeMode } from '../../lib/runtime';

export default function IdentityPage() {
  return <IdentityProfiles mode={runtimeMode()} />;
}
