package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// StateStore persists per-(user,profile) encrypted agent-browser vaults as K8s
// Secrets in the browser namespace. The bytes are already encrypted by
// agent-browser (per-user key); the Secret is opaque storage + at-rest encryption.
type StateStore struct {
	client    kubernetes.Interface
	namespace string
}

func NewStateStore(client kubernetes.Interface, namespace string) *StateStore {
	return &StateStore{client: client, namespace: namespace}
}

func secretName(userID, profile string) string {
	sum := sha256.Sum256([]byte(userID + "\x00" + profile))
	return "bstate-" + hex.EncodeToString(sum[:16])
}

func (s *StateStore) Put(ctx context.Context, userID, profile string, vault []byte) error {
	name := secretName(userID, profile)
	sec := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: s.namespace,
			Labels:    map[string]string{"app": "browser-state"},
		},
		Data: map[string][]byte{"vault.enc": vault},
	}
	_, err := s.client.CoreV1().Secrets(s.namespace).Create(ctx, sec, metav1.CreateOptions{})
	if apierrors.IsAlreadyExists(err) {
		_, err = s.client.CoreV1().Secrets(s.namespace).Update(ctx, sec, metav1.UpdateOptions{})
	}
	if err != nil {
		return fmt.Errorf("store vault: %w", err)
	}
	return nil
}

func (s *StateStore) Get(ctx context.Context, userID, profile string) ([]byte, bool, error) {
	name := secretName(userID, profile)
	sec, err := s.client.CoreV1().Secrets(s.namespace).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("load vault: %w", err)
	}
	return sec.Data["vault.enc"], true, nil
}

func (s *StateStore) Delete(ctx context.Context, userID, profile string) error {
	name := secretName(userID, profile)
	err := s.client.CoreV1().Secrets(s.namespace).Delete(ctx, name, metav1.DeleteOptions{})
	if apierrors.IsNotFound(err) {
		return nil // idempotent
	}
	if err != nil {
		return fmt.Errorf("delete vault: %w", err)
	}
	return nil
}
