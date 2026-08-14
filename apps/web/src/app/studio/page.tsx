import { CreatorStudio } from '../../components/creator-studio';
import { GovernedStudio } from '../../components/governed-studio';
import { runtimeMode } from '../../lib/runtime';

export default function StudioPage() {
  const mode = runtimeMode();
  return mode === 'demo' || mode === 'test' ? <CreatorStudio mode={mode} /> : <GovernedStudio />;
}
