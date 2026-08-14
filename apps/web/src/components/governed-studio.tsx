'use client';

import { useEffect, useMemo, useState } from 'react';
import type { ConsentProfileView, IdentitySampleView, ProjectView, VoiceArtifactView } from '@creator/contracts';
import { VoiceReview } from './voice-review';

type ProfileWithSamples = ConsentProfileView & Readonly<{ samples: IdentitySampleView[] }>;
type VoiceState = Readonly<{
  project: ProjectView;
  script: Readonly<{ id: string; version: number; sha256: string }> | null;
  voiceArtifact: VoiceArtifactView | null;
  voiceApproved: boolean;
  profileStatus: string | null;
}>;

function eligibleVoiceProfile(profile: ProfileWithSamples) {
  return profile.kind === 'voice'
    && profile.status === 'active'
    && profile.samples.some(sample => sample.status === 'validated' && !sample.deletedAt);
}

export function GovernedStudio() {
  const [projects, setProjects] = useState<ProjectView[]>([]);
  const [profiles, setProfiles] = useState<ProfileWithSamples[]>([]);
  const [projectId, setProjectId] = useState('');
  const [profileId, setProfileId] = useState('');
  const [state, setState] = useState<VoiceState | null>(null);
  const [message, setMessage] = useState('Loading governed workspace…');
  const [busy, setBusy] = useState(false);

  const voiceProfiles = useMemo(() => profiles.filter(eligibleVoiceProfile), [profiles]);
  const selectedProject = projects.find(project => project.id === projectId) ?? state?.project ?? null;

  async function loadWorkspace() {
    const [projectResponse, profileResponse] = await Promise.all([
      fetch('/api/creator/projects', { cache: 'no-store' }),
      fetch('/api/creator/identity/profiles', { cache: 'no-store' }),
    ]);
    const projectBody = await projectResponse.json();
    const profileBody = await profileResponse.json();
    if (!projectResponse.ok || !profileResponse.ok) throw new Error('Could not load governed Creator Studio authority.');
    const nextProjects = Array.isArray(projectBody.projects) ? projectBody.projects as ProjectView[] : [];
    const nextProfiles = Array.isArray(profileBody.profiles) ? profileBody.profiles as ProfileWithSamples[] : [];
    setProjects(nextProjects);
    setProfiles(nextProfiles);
    if (!projectId && nextProjects.length) setProjectId(nextProjects[0].id);
    if (!profileId) {
      const firstEligible = nextProfiles.find(eligibleVoiceProfile);
      if (firstEligible) setProfileId(firstEligible.id);
    }
  }

  async function loadState(id = projectId) {
    if (!id) {
      setState(null);
      return;
    }
    const response = await fetch(`/api/creator/projects/${id}/voice`, { cache: 'no-store' });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error ?? 'Could not load voice stage.');
    setState(body as VoiceState);
  }

  useEffect(() => {
    let active = true;
    (async () => {
      try {
        await loadWorkspace();
        if (active) setMessage('Governed workspace loaded.');
      } catch (error) {
        if (active) setMessage(error instanceof Error ? error.message : 'Workspace load failed.');
      }
    })();
    return () => { active = false; };
  // Initial authority discovery only. Project selection has its own effect below.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!projectId) {
      setState(null);
      return;
    }
    loadState(projectId).catch(error => setMessage(error instanceof Error ? error.message : 'Voice stage load failed.'));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId]);

  async function refresh() {
    await Promise.all([loadWorkspace(), loadState()]);
  }

  async function createProject() {
    const title = window.prompt('Project title', 'New video project')?.trim();
    if (!title) return;
    setBusy(true);
    try {
      const response = await fetch('/api/creator/projects', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ title, clientRequestId: crypto.randomUUID() }),
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? 'Project creation failed.');
      await loadWorkspace();
      setProjectId(body.project.id);
      setMessage('Project created. Complete governed content and script approval before requesting voice.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Project creation failed.');
    } finally {
      setBusy(false);
    }
  }

  async function requestVoice() {
    if (!projectId || !profileId) return;
    setBusy(true);
    try {
      const response = await fetch(`/api/creator/projects/${projectId}/voice/request`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ profileId, idempotencyKey: crypto.randomUUID() }),
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? 'Voice request failed.');
      setMessage(body.replayed
        ? 'Voice request already exists.'
        : 'Synthetic voice draft requested. Trusted worker completion is the next gate.');
      await loadState();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Voice request failed.');
    } finally {
      setBusy(false);
    }
  }

  const stage = state?.project.currentStage ?? selectedProject?.currentStage ?? null;

  return <main className="shell">
    <header className="topbar">
      <div>
        <p className="eyebrow">AVALA CREATOR STUDIO</p>
        <h1>Create with your identity. Approve every step.</h1>
        <p className="lede">Production-like mode uses server-authoritative Supabase state. Generation remains synthetic and human-triggered.</p>
      </div>
      <span className="mode">GOVERNED MODE</span>
    </header>

    <section className="notice">Real TTS inference, avatar generation and publishing remain disabled. B1 proves the private review lifecycle first.</section>

    <section className="governedToolbar">
      <label>Project
        <select value={projectId} onChange={event => setProjectId(event.target.value)}>
          <option value="">Select project</option>
          {projects.map(project => <option key={project.id} value={project.id}>{project.title}</option>)}
        </select>
      </label>
      <button className="secondary" onClick={createProject} disabled={busy}>New project</button>
      <button className="secondary" onClick={() => refresh()} disabled={busy || !projectId}>Refresh</button>
    </section>

    <section className="governedWorkspace">
      <div className="stageCard">
        <p className="eyebrow">CURRENT STAGE</p>
        <h2>{stage ?? 'No project selected'}</h2>
        <p className="hint">Voice unlocks only after the exact latest script has a current human approval.</p>
      </div>
      <p className="status" aria-live="polite">{message}</p>

      {stage === 'SCRIPT_APPROVED' && <section className="voiceRequestCard">
        <h3>Request synthetic voice draft</h3>
        <p className="hint">Choose an active self-owned voice profile with a validated sample. No TTS model runs in B1.</p>
        <select value={profileId} onChange={event => setProfileId(event.target.value)}>
          <option value="">Select eligible voice profile</option>
          {voiceProfiles.map(profile => <option key={profile.id} value={profile.id}>{profile.displayName}</option>)}
        </select>
        <button className="primary" onClick={requestVoice} disabled={busy || !profileId || !state?.script}>Request synthetic draft</button>
      </section>}

      {stage === 'VOICE_GENERATING' && <section className="available">
        <strong>Trusted worker gate</strong>
        <p>The human request is recorded. Only service-role authority may complete the synthetic draft and move the project to VOICE_REVIEW.</p>
      </section>}

      {(stage === 'VOICE_REVIEW' || stage === 'VOICE_APPROVED') && state?.voiceArtifact && <VoiceReview
        projectId={state.project.id}
        artifact={state.voiceArtifact}
        profileStatus={state.profileStatus}
        approved={state.voiceApproved}
        onChange={refresh}
      />}

      {stage && !['SCRIPT_APPROVED', 'VOICE_GENERATING', 'VOICE_REVIEW', 'VOICE_APPROVED'].includes(stage) && <section className="available">
        <strong>Voice stage locked</strong>
        <p>Complete the governed content and script stages first.</p>
      </section>}
    </section>
  </main>;
}
