import { CreatorStudio } from '../components/creator-studio';
import { runtimeMode } from '../lib/runtime';

export default function HomePage() {
  return <CreatorStudio mode={runtimeMode()} />;
}
