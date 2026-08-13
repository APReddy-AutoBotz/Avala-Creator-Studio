'use client';

import { useEffect, useState } from 'react';
import { SELF_OWNED_CONSENT, type ConsentProfileView, type IdentityProfileKind, type IdentitySampleView } from '@creator/contracts';
import type { RuntimeMode } from '../lib/runtime';
import { createCreatorSupabaseBrowserClient } from '../lib/supabase/browser';
import styles from './identity-profiles.module.css';

type ProfileWithSamples = ConsentProfileView & { samples: IdentitySampleView[] };

async function sha256Hex(input: ArrayBuffer) {
  const digest = await crypto.subtle.digest('SHA-256', input);
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
    if (!mock) void refresh();
  }, [mock]);

  async function refresh() {
    try {
      const data = await jsonRequest('/api/creator/identity/profiles');
      setProfiles(data.profiles ?? []);
      setMessage('Profiles loaded. Only active profiles with validated samples are generation-eligible.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'LOAD_FAILED');
    }
  }

  async function createProfile() {
    if (!consented || !displayName.trim()) return;
    setBusy(true);
    try {
      const governed = SELF_OWNED_CONSENT[kind];
      if (mock) {
        setProfiles(value => [...value, {
          id: crypto.randomUUID(), kind, displayName: displayName.trim(),
          consentStatementVersion: governed.version, consentSha256: governed.sha256,
          status: 'draft', createdAt: new Date().toISOString(), activatedAt: null,
          revokedAt: null, deletedAt: null, samples: [],
        }]);
        setMessage('Synthetic demo profile created locally. No media or cloud data was written.');
      } else {
        await jsonRequest('/api/creator/identity/profiles', {
          method: 'POST',
          body: JSON.stringify({
            kind, displayName: displayName.trim(), consentStatementVersion: governed.version,
            consentSha256: governed.sha256, clientRequestId: crypto.randomUUID(),
          }),
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
      const { error } = await supabase.storage.from('creator-private').upload(
        prepared.objectPath, file, { contentType: file.type, upsert: false },
      );
      if (error) throw new Error('PRIVATE_UPLOAD_FAILED');

      await jsonRequest(`/api/creator/identity/profiles/${profile.id}/samples`, {
        method: 'POST', body: JSON.stringify({ clientRequestId }),
      });
      await refresh();
      setMessage('Private sample uploaded and registered as pending validation. It cannot be used for generation yet.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'UPLOAD_FAILED');
    } finally {
      setBusy(false);
    }
  }

  async function activate(profile: ProfileWithSamples) {
    if (mock) {
      if (!profile.samples.some(sample => sample.status === 'validated')) {
        setMessage('A validated sample is required before activation.');
        return;
      }
      setProfiles(items => items.map(item => item.id === profile.id ? { ...item, status: 'active', activatedAt: new Date().toISOString() } : item));
      return;
    }
    setBusy(true);
    try {
      await jsonRequest(`/api/creator/identity/profiles/${profile.id}/activate`, {
        method: 'POST', body: JSON.stringify({ idempotencyKey: crypto.randomUUID() }),
      });
      await refresh();
      setMessage('Profile activated. Generation remains human-triggered and inference is still disabled in M2.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'ACTIVATE_FAILED');
    } finally { setBusy(false); }
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
      setMessage('Consent revoked. Profile-dependent artifacts, reviews and active downstream jobs are invalidated.');
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
      setMessage('Profile deletion completed after upload shutdown and private-media cleanup.');
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'DELETE_FAILED');
    } finally { setBusy(false); }
  }

  return <main className={styles.shell}>
    <a className={styles.back} href="/studio">← Back to Studio</a>
    <header className={styles.header}>
      <div><h1>Consent-bound identity profiles</h1><p>Create separate self-owned voice and avatar profiles. Consent can be revoked at any time; media remains unusable until trusted validation and explicit activation.</p></div>
      <span className={styles.badge}>{mock ? 'SYNTHETIC DEMO' : mode.toUpperCase()}</span>
    </header>
    <div className={styles.notice}>Real voice cloning and avatar inference are disabled in M2. The public repository contains no identity media.</div>
    <section className={styles.grid}>
      <article className={styles.card}>
        <h2>Create profile</h2>
        <label className={styles.field}>Profile type<select value={kind} onChange={event => { const next = event.target.value as IdentityProfileKind; setKind(next); setDisplayName(next === 'voice' ? 'My voice' : 'My avatar'); }}><option value="voice">Voice</option><option value="avatar">Avatar</option></select></label>
        <label className={styles.field}>Display name<input value={displayName} onChange={event => setDisplayName(event.target.value)} maxLength={120}/></label>
        <label className={styles.consent}><input type="checkbox" checked={consented} onChange={event => setConsented(event.target.checked)}/><span>{SELF_OWNED_CONSENT[kind].text}</span></label>
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
            <label className={styles.secondary}>Add private sample<input hidden type="file" disabled={mock || busy || profile.status === 'revoked' || profile.status === 'deleting' || profile.status === 'deleted'} accept={profile.kind === 'voice' ? 'audio/*' : 'image/*,video/*'} onChange={event => void uploadSample(profile, event.target.files?.[0] ?? null)}/></label>
            <button className={styles.primary} disabled={busy || profile.status !== 'draft' || !profile.samples.some(sample => sample.status === 'validated')} onClick={() => void activate(profile)}>Activate validated profile</button>
            <button className={styles.danger} disabled={busy || profile.status === 'revoked' || profile.status === 'deleting' || profile.status === 'deleted'} onClick={() => void revoke(profile)}>Revoke consent</button>
            <button className={styles.danger} disabled={busy || profile.status === 'deleted'} onClick={() => void remove(profile)}>{profile.status === 'deleting' ? 'Retry deletion' : 'Delete profile'}</button>
          </div>
        </div>)}
      </article>
    </section>
  </main>;
}
