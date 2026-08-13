'use client';

import { useEffect, useState } from 'react';
import type { ConsentProfileView, IdentityProfileKind, IdentitySampleView } from '@creator/contracts';
import type { RuntimeMode } from '../lib/runtime';
import { createCreatorSupabaseBrowserClient } from '../lib/supabase/browser';
import styles from './identity-profiles.module.css';

type ProfileWithSamples = ConsentProfileView & { samples: IdentitySampleView[] };

const CONSENT_TEXT: Record<IdentityProfileKind, string> = {
  voice: 'I confirm that this is my own voice and authorize Avala Creator Studio to use the submitted sample only for my requested synthetic narration workflow.',
  avatar: 'I confirm that this is my own likeness and authorize Avala Creator Studio to use the submitted sample only for my requested synthetic avatar workflow.',
};

async function sha256Hex(input: string | ArrayBuffer) {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : input;
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest)).map(value => value.toString(16).padStart(2, '0')).join('');
}

async function jsonRequest(url: string, init?: RequestInit) {
  const response = await fetch(url, { ...init, headers: { 'content-type': 'application/json', ...(init?.headers ?? {}) } });
  const body = await response.json();
  if (!response.ok) throw new Error(body?.code ?? body?.error ?? 'REQUEST_FAILED');
  return body;
}

export function IdentityProfiles({ mode }: { mode: RuntimeMode }) {
  const mock = mode === 'demo' || mode === 'test';
  const [kind, setKind] = useState<IdentityProfileKind>('voice');
  const [displayName, setDisplayName] = useState('My voice');
  const [consented, setConsented] = useState(false);
  const [profiles, setProfiles] = useState<ProfileWithSamples[]>([]);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState(mock ? 'Demo mode never uploads real identity media.' : 'Loading identity profiles…');

  useEffect(() => {
    if (mock) return;
    void refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mock]);

  async function refresh() {
    try {
      const data = await jsonRequest('/api/creator/identity/profiles');
      setProfiles(data.profiles ?? []);
      setMessage('Profiles loaded. Pending/rejected samples are never generation-eligible.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'LOAD_FAILED');
    }
  }

  async function createProfile() {
    if (!consented || !displayName.trim()) return;
    setBusy(true);
    try {
      const consentSha256 = await sha256Hex(CONSENT_TEXT[kind]);
      if (mock) {
        setProfiles(value => [...value, {
          id: crypto.randomUUID(), kind, displayName: displayName.trim(), consentStatementVersion: 'self-owned-v1',
          consentSha256, status: 'draft', createdAt: new Date().toISOString(), activatedAt: null,
          revokedAt: null, deletedAt: null, samples: [],
        }]);
        setMessage('Synthetic demo profile created locally. No media or cloud data was written.');
      } else {
        await jsonRequest('/api/creator/identity/profiles', {
          method: 'POST',
          body: JSON.stringify({ kind, displayName: displayName.trim(), consentStatementVersion: 'self-owned-v1', consentSha256, clientRequestId: crypto.randomUUID() }),
        });
        await refresh();
      }
      setConsented(false);
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'CREATE_FAILED');
    } finally {
      setBusy(false);
    }
  }

  async function uploadSample(profile: ProfileWithSamples, file: File | null) {
    if (!file || mock) return;
    setBusy(true);
    try {
      const sha256 = await sha256Hex(await file.arrayBuffer());
      const clientRequestId = crypto.randomUUID();
      const prepared = await jsonRequest(`/api/creator/identity/profiles/${profile.id}/upload`, {
        method: 'POST',
        body: JSON.stringify({ fileName: file.name, mimeType: file.type, byteLength: file.size, sha256, clientRequestId }),
      });
      const supabase = createCreatorSupabaseBrowserClient();
      const { error } = await supabase.storage.from('creator-private').uploadToSignedUrl(
        prepared.objectPath, prepared.token, file, { contentType: file.type, upsert: false },
      );
      if (error) throw new Error('PRIVATE_UPLOAD_FAILED');
      await jsonRequest(`/api/creator/identity/profiles/${profile.id}/samples`, {
        method: 'POST',
        body: JSON.stringify({ objectPath: prepared.objectPath, mimeType: file.type, byteLength: file.size, sha256, clientRequestId }),
      });
      await refresh();
      setMessage('Private sample uploaded and registered as pending validation. It cannot be used for generation yet.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'UPLOAD_FAILED');
    } finally {
      setBusy(false);
    }
  }

  async function revoke(profile: ProfileWithSamples) {
    if (mock) {
      setProfiles(items => items.map(item => item.id === profile.id ? { ...item, status: 'revoked', revokedAt: new Date().toISOString() } : item));
      setMessage('Synthetic demo consent revoked.');
      return;
    }
    setBusy(true);
    try {
      await jsonRequest(`/api/creator/identity/profiles/${profile.id}/revoke`, {
        method: 'POST', body: JSON.stringify({ reason: 'User revoked consent from profile management.', idempotencyKey: crypto.randomUUID() }),
      });
      await refresh();
      setMessage('Consent revoked. Active/pending work using this profile is no longer authoritative.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'REVOKE_FAILED');
    } finally { setBusy(false); }
  }

  async function remove(profile: ProfileWithSamples) {
    if (mock) {
      setProfiles(items => items.filter(item => item.id !== profile.id));
      setMessage('Synthetic demo profile deleted locally.');
      return;
    }
    setBusy(true);
    try {
      await jsonRequest(`/api/creator/identity/profiles/${profile.id}/delete`, {
        method: 'POST', body: JSON.stringify({ idempotencyKey: crypto.randomUUID() }),
      });
      await refresh();
      setMessage('Profile media deletion completed and sensitive sample metadata was cleared from active records.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'DELETE_FAILED');
    } finally { setBusy(false); }
  }

  return <main className={styles.shell}>
    <a className={styles.back} href="/studio">← Back to Studio</a>
    <header className={styles.header}>
      <div><h1>Consent-bound identity profiles</h1><p>Create separate self-owned voice and avatar profiles. Consent can be revoked at any time; uploaded media remains unusable until trusted validation succeeds.</p></div>
      <span className={styles.badge}>{mock ? 'SYNTHETIC DEMO' : mode.toUpperCase()}</span>
    </header>
    <div className={styles.notice}>Real voice cloning and avatar inference are disabled in M2. The public repository contains no identity media.</div>
    <section className={styles.grid}>
      <article className={styles.card}>
        <h2>Create profile</h2>
        <label className={styles.field}>Profile type<select value={kind} onChange={event => { const next = event.target.value as IdentityProfileKind; setKind(next); setDisplayName(next === 'voice' ? 'My voice' : 'My avatar'); }}><option value="voice">Voice</option><option value="avatar">Avatar</option></select></label>
        <label className={styles.field}>Display name<input value={displayName} onChange={event => setDisplayName(event.target.value)} maxLength={120}/></label>
        <label className={styles.consent}><input type="checkbox" checked={consented} onChange={event => setConsented(event.target.checked)}/><span>{CONSENT_TEXT[kind]}</span></label>
        <button className={styles.primary} disabled={!consented || busy} onClick={() => void createProfile()}>Create consent profile</button>
        <p className={styles.message} aria-live="polite">{message}</p>
      </article>
      <article className={styles.card}>
        <h2>Your profiles</h2>
        {profiles.length === 0 && <p>No profiles yet.</p>}
        {profiles.map(profile => <div className={styles.profile} key={profile.id}>
          <div className={styles.profileHeader}><strong>{profile.displayName} · {profile.kind}</strong><span className={styles.status}>{profile.status}</span></div>
          {profile.samples.map(sample => <div className={styles.sample} key={sample.id}>Sample: <strong>{sample.status}</strong>{sample.rejectionCode ? ` · ${sample.rejectionCode}` : ''}</div>)}
          <div className={styles.actions}>
            <label className={styles.secondary}>Add private sample<input hidden type="file" disabled={mock || busy || profile.status === 'revoked' || profile.status === 'deleted'} accept={profile.kind === 'voice' ? 'audio/*' : 'image/*,video/*'} onChange={event => void uploadSample(profile, event.target.files?.[0] ?? null)}/></label>
            <button className={styles.danger} disabled={busy || profile.status === 'revoked' || profile.status === 'deleted'} onClick={() => void revoke(profile)}>Revoke consent</button>
            <button className={styles.danger} disabled={busy || profile.status === 'deleted'} onClick={() => void remove(profile)}>Delete profile</button>
          </div>
        </div>)}
      </article>
    </section>
  </main>;
}
