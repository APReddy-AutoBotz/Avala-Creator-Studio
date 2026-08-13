import { CreatorStudio } from '../../components/creator-studio';
import { runtimeMode } from '../../lib/runtime';

export default function StudioPage() {
  return <CreatorStudio mode={runtimeMode()} />;
}
