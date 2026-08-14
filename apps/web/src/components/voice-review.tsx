'use client';

import { useState } from 'react';
import { SYNTHETIC_MOCK_VOICE_LABEL, type VoiceArtifactView } from '@creator/contracts';

export function VoiceReview({
  projectId,
  artifact,
  profileStatus,
  approved,
  onChange,
}: Readonly<{
  projectId: string;
  artifact: VoiceArtifactView;
  profileStatus: string | null;
  approved: boolean;
  onChange: () => Promise<void>;
}>) {
  const [notes, setNotes] = useState('');
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [message, setMessage] = useState('Review the exact audio version before approval.');
  const [busy, setBusy] = useState(false);
  const actionsDisabled = busy || approved || Boolean(artifact.staleAt) || profileStatus !== 'active';

  async function loadPreview() {
    setBusy(true);
    try {
      const response = await fetch(`/api/creator/projects/${projectId}/voice/${artifact.id}/preview`, { method: 'POST' });
      const body = await response.json();
      if (!response.ok || typeof body.url !== 'string') throw new Error(body.error ?? 'Preview is not available.');
      setPreviewUrl(body.url);
      setMessage('Authenticated private preview ready. Consent is rechecked when audio bytes are requested.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Preview failed.');
    } finally {
      setBusy(false);
    }
  }

  async function submit(decision: 'approve' | 'revise') {
    const cleanNotes = notes.trim();
    if (!cleanNotes) {
      setMessage('Add review notes before continuing.');
      return;
    }
    setBusy(true);
    try {
      const path = decision === 'approve' ? 'approve' : 'revision';
      const payload = decision === 'approve'
        ? { artifactSha256: artifact.sha256, notes: cleanNotes, idempotencyKey: crypto.randomUUID() }
        : { artifactSha256: artifact.sha256, reason: cleanNotes, idempotencyKey: crypto.randomUUID() };
      const response = await fetch(`/api/creator/projects/${projectId}/voice/${artifact.id}/${path}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? 'Review action failed.');
      setPreviewUrl(null);
      setMessage(decision === 'approve'
        ? 'This exact voice version is approved.'
        : 'Voice revision requested. The current audio is stale and queued for deletion.');
      await onChange();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Review action failed.');
    } finally {
      setBusy(false);
    }
  }

  return <section className="voiceReviewCard">
    <div className="voiceReviewHeader">
      <div>
        <p className="eyebrow">STAGE 3</p>
        <h2>Review voice draft</h2>
      </div>
      <span className="syntheticBadge">{SYNTHETIC_MOCK_VOICE_LABEL}</span>
    </div>
    <p className="hint">This is deterministic test audio, not cloned speech. Nothing moves forward until you approve this exact digest.</p>

    <div className="voiceAudioPanel">
      {previewUrl
        ? <audio
            controls
            preload="none"
            src={previewUrl}
            onError={() => {
              setPreviewUrl(null);
              setMessage('Preview authority changed or the audio is no longer available. Reload the preview to recheck consent.');
            }}
          />
        : <p className="hint">Audio stays private. Each preview request is authenticated and rechecks current consent.</p>}
      <button className="secondary" onClick={loadPreview} disabled={busy || Boolean(artifact.staleAt)}>Load authenticated preview</button>
    </div>

    <div className="evidenceGrid">
      <div><span>Version</span><strong>{artifact.version}</strong></div>
      <div><span>Provider</span><strong>{artifact.metadata.providerId}</strong></div>
      <div><span>Script version</span><strong>{artifact.metadata.script.artifactVersion}</strong></div>
      <div><span>Runtime</span><strong>{artifact.metadata.runtimeMs} ms</strong></div>
      <div><span>Cost</span><strong>$0.00</strong></div>
      <div><span>Profile</span><strong>{profileStatus ?? 'unavailable'}</strong></div>
    </div>

    <label htmlFor="voiceNotes">Review notes</label>
    <textarea id="voiceNotes" className="notes" value={notes} onChange={event => setNotes(event.target.value)} placeholder="Record what you heard, what should change, or why this version is ready." />
    <p className="status" aria-live="polite">{message}</p>
    <div className="actions">
      <button className="secondary" onClick={() => submit('revise')} disabled={actionsDisabled}>Request revision</button>
      <button className="primary" onClick={() => submit('approve')} disabled={actionsDisabled}>Approve exact version</button>
    </div>
  </section>;
}
