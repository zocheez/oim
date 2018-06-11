/*
Copyright (C) 2018 Intel Corporation.

SPDX-License-Identifier: Apache-2.0
*/

package oimcontroller_test

import (
	"log"
	"testing"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
)

func init() {
	log.SetOutput(GinkgoWriter)
}

func TestOIMController(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "OIM Controller Suite")
}
