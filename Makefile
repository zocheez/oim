# Copyright 2017 The Kubernetes Authors.
# Copyright 2018 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

IMPORT_PATH=github.com/intel/oim

REGISTRY_NAME=localhost:5000
IMAGE_VERSION_oim-csi-driver=canary
IMAGE_TAG=$(REGISTRY_NAME)/$*:$(IMAGE_VERSION_$*)

OIM_CMDS=oim-controller oim-csi-driver oim-registry

# Build main set of components.
.PHONY: all
all: $(OIM_CMDS)

# Build all binaries, including tests.
# Must use the workaround from https://github.com/golang/go/issues/15513
build: $(OIM_CMDS)
	go test -run none $(TEST_ALL)

# Run operations only developers should need after making code changes.
update:
.PHONY: update

# By default, testing only runs tests that work without additional components.
# Additional tests can be enabled by overriding the following makefile variables
# or (when invoking go test manually) by setting the corresponding env variables

# Unix domain socket path of a running SPDK vhost.
# TEST_SPDK_VHOST_SOCKET=

# Alternatively, the path to a spdk/app/vhost binary can be provided.
# Use "_work/vhost" and that binary will be built automatically in _work.
# TEST_SPDK_VHOST_BINARY=

# Image base name to boot under QEMU before running tests, for example
# "_work/clear-kvm.img".
# TEST_QEMU_IMAGE=

# If Ginkgo is available, then testing can be sped up by using
# TEST_CMD=ginkgo -p.
TEST_CMD=go test -timeout 0
TEST_ALL=$(IMPORT_PATH)/pkg/... $(IMPORT_PATH)/test/e2e
TEST_ARGS=$(IMPORT_PATH)/pkg/... $(if $(_TEST_QEMU_IMAGE), $(IMPORT_PATH)/test/e2e)

.PHONY: test
test: all vet run_tests

# TODO: add -shadow
.PHONY: vet
vet:
	go vet $(IMPORT_PATH)/pkg/... $(IMPORT_PATH)/cmd/...

# golint may sometimes be too strict and intentionally has
# no way to suppress uninteded warnings, but it finds real
# issues, so we try to become complete free of warnings.
# Right now only some parts of the code pass, so the test
# target only checks those to avoid regressions.
#
# golint might not be installed, so we skip the test if
# that is the case.
.PHONY: lint test_lint
test: test_lint
lint:
	golint $(IMPORT_PATH)/pkg/... $(IMPORT_PATH)/cmd/...
test_lint:
	@ golint -help >/dev/null 2>&1; if [ $$? -eq 2 ]; then echo "running golint..."; golint -set_exit_status $(IMPORT_PATH)/pkg/log; fi

# Check resp. fix formatting.
.PHONY: test_fmt fmt
test: test_fmt
test_fmt:
	@ files=$$(find pkg cmd test -name '*.go'); \
	if [ $$(gofmt -d $$files | wc -l) -ne 0 ]; then \
		echo "formatting errors:"; \
		gofmt -d $$files; \
		false; \
	fi
fmt:
	gofmt -l -w $$(find pkg cmd test -name '*.go')

# Determine whether we have QEMU and SPDK.
_TEST_QEMU_IMAGE=$(if $(TEST_QEMU_IMAGE),$(TEST_QEMU_IMAGE),$(if $(WITH_E2E_TESTS),_work/clear-kvm.img))
_TEST_SPDK_VHOST_BINARY=$(if $(TEST_SPDK_VHOST_BINARY),$(TEST_SPDK_VHOST_BINARY),$(if $(WITH_E2E_TESTS),_work/vhost))

# Derive filenames of helper files from QEMU image name.
TEST_QEMU_PREFIX=$(if $(_TEST_QEMU_IMAGE),$(dir $(_TEST_QEMU_IMAGE))$(1)-$(notdir $(basename $(_TEST_QEMU_IMAGE))))
TEST_QEMU_START=$(call TEST_QEMU_PREFIX,start)
TEST_QEMU_SSH=$(call TEST_QEMU_PREFIX,ssh)
TEST_QEMU_KUBE=$(call TEST_QEMU_PREFIX,kube)
TEST_QEMU_DEPS=$(_TEST_QEMU_IMAGE) $(TEST_QEMU_START) $(TEST_QEMU_SSH) $(TEST_QEMU_KUBE)

# We only need to build and push the latest OIM CSI driver if we actually use it during testing.
TEST_E2E_DEPS=$(if $(filter $(IMPORT_PATH)/test/e2e, $(TEST_ARGS)), push-oim-csi-driver)

.PHONY: run_tests
run_tests: $(TEST_QEMU_DEPS) $(_TEST_SPDK_VHOST_BINARY) $(TEST_E2E_DEPS) oim-csi-driver
	mkdir -p _work
	cd _work && \
	TEST_OIM_CSI_DRIVER_BINARY=$(abspath _output/oim-csi-driver) \
	TEST_SPDK_VHOST_SOCKET=$(abspath $(TEST_SPDK_VHOST_SOCKET)) \
	TEST_SPDK_VHOST_BINARY=$(abspath $(_TEST_SPDK_VHOST_BINARY)) \
	TEST_QEMU_IMAGE=$(abspath $(_TEST_QEMU_IMAGE)) \
	    $(TEST_CMD) $$( go list $(TEST_ARGS) | sed -e 's;$(IMPORT_PATH);../;' )

.PHONY: force_test
force_test: clean_testcache test

# go caches test results. If we want to rerun tests because e.g. SPDK
# was restarted, then we must throw away cached results first.
.PHONY: clean_testcache
clean_testcache:
	go clean -testcache

# oim-registry and oim-controller should not contain glog, while
# oim-csi-driver still does (via Kubernetes).
.PHONY: test_no_glog
test: test_no_glog
test_no_glog: oim-controller oim-registry
	@ for i in $+; do if _output/$$i --help 2>&1 | grep -q -e -alsologtostderr; then echo "ERROR: $$i contains glog!"; exit 1; fi; done

.PHONY: coverage
coverage:
	mkdir -p _work
	go test -coverprofile _work/cover.out $(IMPORT_PATH)/pkg/...
	go tool cover -html=_work/cover.out -o _work/cover.html

.PHONY: $(OIM_CMDS)
$(OIM_CMDS):
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-extldflags "-static"' -o _output/$@ ./cmd/$@

# _output is used as the build context. All files inside it are sent
# to the Docker daemon when building images.
%-container: %
	cp cmd/$*/Dockerfile _output/Dockerfile.$*
	cd _output && \
	docker build \
		--build-arg HTTP_PROXY \
		--build-arg HTTPS_PROXY \
		--build-arg NO_PROXY \
		-t $(IMAGE_TAG) -f Dockerfile.$* .

push-%: %-container
	docker push $(IMAGE_TAG)

.PHONY: clean
clean:
	go clean -r -x
	-rm -rf _output _work

# Sanitize proxy settings (accept upper and lower case, set and export upper
# case) and add local machine to no_proxy because some tests may use a
# local Docker registry. Also exclude 0.0.0.0 because otherwise Go
# tests using that address try to go through the proxy.
HTTP_PROXY=$(shell echo "$${HTTP_PROXY:-$${http_proxy}}")
HTTPS_PROXY=$(shell echo "$${HTTPS_PROXY:-$${https_proxy}}")
NO_PROXY=$(shell echo "$${NO_PROXY:-$${no_proxy}},$$(ip addr | grep inet6 | grep /64 | sed -e 's;.*inet6 \(.*\)/64 .*;\1;' | tr '\n' ','; ip addr | grep -w inet | grep /24 | sed -e 's;.*inet \(.*\)/24 .*;\1;' | tr '\n' ',')",$$(hostname),0.0.0.0)
export HTTP_PROXY HTTPS_PROXY NO_PROXY
PROXY_ENV=env 'HTTP_PROXY=$(HTTP_PROXY)' 'HTTPS_PROXY=$(HTTPS_PROXY)' 'NO_PROXY=$(NO_PROXY)'

# Downloads and unpacks the latest Clear Linux KVM image.
# This intentionally uses a different directory, otherwise
# we would end up sending the KVM images to the Docker
# daemon when building new Docker images as part of the
# build context.
#
# Sets the image up so that "ssh" works as root with a random
# password (stored in _work/passwd) and with _work/id as
# new private ssh key.
#
# Using chat for this didn't work because chat connected to
# qemu via pipes complained about unsupported ioctls. Expect
# would have been another alternative, but wasn't tried.
#
# Using plain bash might be a bit more brittle and harder to read, but
# at least it avoids extra dependencies.  Inspired by
# http://wiki.bash-hackers.org/syntax/keywords/coproc
#
# A registry on the build host (i.e. localhost:5000) is marked
# as insecure in Clear Linux under the hostname of the build host.
# Otherwise pulling images fails.
#
# The latest upstream Kubernetes binaries are used because that way
# the resulting installation is always up-to-date. Some workarounds
# in systemd units are necessary to get that up and running.
#
# The resulting cluster has:
# - a single node with the master taint removed
# - networking managed by kubelet itself
#
# Kubernetes does not get started by default because it might
# not always be needed in the image, depending on the test.
# _work/kube-clear-kvm can be used to start it.

SHELL=bash
RELEASE=$(shell curl -sSL https://dl.k8s.io/release/stable.txt)
KUBEADM=/opt/bin/kubeadm
_work/clear-kvm-original.img:
	mkdir -p _work && \
	cd _work && \
	dd if=/dev/random bs=1 count=8 2>/dev/null | od -A n -t x8 >passwd | sed -e 's/ //g' && \
	version=$$(curl https://download.clearlinux.org/image/ 2>&1 | grep clear-.*-kvm.img.xz | sed -e 's/.*clear-\([0-9]*\)-kvm.img.*/\1/' | sort -u -n | tail -1) && \
	[ "$$version" ] && \
	curl -O https://download.clearlinux.org/image/clear-$$version-kvm.img.xz && \
	curl -O https://download.clearlinux.org/image/clear-$$version-kvm.img.xz-SHA512SUMS && \
	curl -O https://download.clearlinux.org/image/clear-$$version-kvm.img.xz-SHA512SUMS.sig && \
	(echo 'skipping image verification, does not work at the moment (https://github.com/clearlinux/distribution/issues/85)' && true || openssl smime -verify -in clear-$$version-kvm.img.xz-SHA512SUMS.sig -inform der -content clear-$$version-kvm.img.xz-SHA512SUMS -CAfile ../test/ClearLinuxRoot.pem -out /dev/null) && \
	sed -e 's;/.*/;;' clear-$$version-kvm.img.xz-SHA512SUMS | sha512sum -c && \
	unxz -c <clear-$$version-kvm.img.xz >clear-kvm-original.img

_work/clear-kvm.img _work/kube-clear-kvm: _work/clear-kvm-original.img _work/OVMF.fd _work/start-clear-kvm _work/ssh-clear-kvm _work/id
	set -x && \
	cp $< $@ && \
	cd _work && \
	coproc { ./start-clear-kvm clear-kvm.img | tee serial.log ;} && \
	trap '[ "$$COPROC_PID" ] && kill $$COPROC_PID' EXIT && \
	echo "Waiting for initial root login, see $$(pwd)/serial.log" && \
	while IFS= read -d : -ru $${COPROC[0]} x && ! [[ "$$x" =~ "login" ]]; do :; done && \
	echo "Give Clear Linux some time to finish booting." && \
	sleep 5 && \
	echo "Changing root password..." && \
	echo "root" >&$${COPROC[1]} && \
	while IFS= read -d : -ru $${COPROC[0]} x && ! [[ "$$x" =~ "New password" ]]; do :; done && \
	echo "root$$(cat passwd)" >&$${COPROC[1]} && \
	while IFS= read -d : -ru $${COPROC[0]} x && ! [[ "$$x" =~ "Retype new password" ]]; do :; done && \
	echo "root$$(cat passwd)" >&$${COPROC[1]} && \
	echo "Reconfiguring and shutting down..." && \
	IFS= read -d '#' -ru $${COPROC[0]} x && \
	echo "mkdir -p /etc/ssh && echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && mkdir -p .ssh && echo '$$(cat id.pub)' >>.ssh/authorized_keys" >&$${COPROC[1]} && \
	echo "configuring Kubernetes" && \
	./ssh-clear-kvm "$(PROXY_ENV) swupd bundle-add cloud-native-basic" && \
	./ssh-clear-kvm 'systemctl daemon-reload' && \
	./ssh-clear-kvm 'ln -s /usr/share/defaults/etc/hosts /etc/hosts' && \
	./ssh-clear-kvm 'mkdir -p /etc/systemd/system/kubelet.service.d/' && \
	echo "Downloading Kubernetes $(RELEASE)." && \
	./ssh-clear-kvm	'mkdir -p /opt/bin && cd /opt/bin && for i in kubeadm kubelet kubectl; do $(PROXY_ENV) curl -L --remote-name-all https://storage.googleapis.com/kubernetes-release/release/$(RELEASE)/bin/linux/amd64/$$i && chmod +x $$i; done' && \
	echo "Using a mixture of Clear Linux CNI plugins (/usr/libexec/cni/) and plugins downloaded via pods (/opt/cni/bin)" && \
	./ssh-clear-kvm "( echo '[Service]'; echo 'Environment=\"KUBELET_EXTRA_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --runtime-request-timeout=30m --fail-swap-on=false --cni-bin-dir=/opt/cni/bin --allow-privileged=true --feature-gates=CSIPersistentVolume=true,MountPropagation=true\"'; echo 'Environment=\"KUBELET_NETWORK_ARGS=\"'; echo 'ExecStart='; grep ^ExecStart= /lib/systemd/system/kubelet.service | sed -e 's;/usr/bin/kubelet;/opt/bin/kubelet;' ) >/etc/systemd/system/kubelet.service.d/oim.conf" && \
	./ssh-clear-kvm 'mkdir -p /opt/cni/bin/; for i in /usr/libexec/cni/*; do ln -s $$i /opt/cni/bin/; done' && \
	./ssh-clear-kvm 'mkdir -p /etc/systemd/system/docker.service.d/' && \
	./ssh-clear-kvm "( echo '[Service]'; echo 'Environment=\"HTTP_PROXY=$(HTTP_PROXY)\" \"HTTPS_PROXY=$(HTTPS_PROXY)\" \"NO_PROXY=$(NO_PROXY)\"'; echo 'ExecStart='; echo 'ExecStart=/usr/bin/dockerd --storage-driver=overlay2 --default-runtime=runc' ) >/etc/systemd/system/docker.service.d/oim.conf" && \
	./ssh-clear-kvm "mkdir -p /etc/docker && echo '{ \"insecure-registries\":[\"$$(hostname):5000\"] }' >/etc/docker/daemon.json" && \
	./ssh-clear-kvm 'systemctl daemon-reload && systemctl restart docker' && \
	./ssh-clear-kvm '$(KUBEADM) init --apiserver-cert-extra-sans localhost --kubernetes-version $(RELEASE) --ignore-preflight-errors=Swap,SystemVerification,CRI,KubeletVersion' && \
	./ssh-clear-kvm 'mkdir -p .kube' && \
	./ssh-clear-kvm 'cp -i /etc/kubernetes/admin.conf .kube/config' && \
	./ssh-clear-kvm 'kubectl taint nodes --all node-role.kubernetes.io/master-' && \
	./ssh-clear-kvm 'kubectl get pods --all-namespaces' && \
	echo "Use $$(pwd)/clear-kvm-kube.config as KUBECONFIG to access the running cluster." && \
	./ssh-clear-kvm 'cat /etc/kubernetes/admin.conf' | sed -e 's;https://.*:6443;https://localhost:16443;' >clear-kvm-kube.config && \
	( echo "#!/bin/sh -e"; echo "$$(pwd)/ssh-clear-kvm 'systemctl start docker && systemctl start kubelet'"; echo 'cnt=0; while [ $$cnt -lt 60 ]; do'; echo "if $$(pwd)/ssh-clear-kvm kubectl get nodes >/dev/null 2>/dev/null; then exit 0; fi;"; echo 'cnt=$$(expr $$cnt + 1); sleep 1; done; echo timed out waiting for Kubernetes; exit 1' ) >kube-clear-kvm && chmod a+rx kube-clear-kvm && \
	./kube-clear-kvm && \
	echo "shutdown now" >&$${COPROC[1]} && wait

# This workaround was needed when using kubeadm 1.9 to set up a kubernetes 1.10 cluster,
# because of a kube-proxy config change:
#	./ssh-clear-kvm 'for i in kube-proxy kubeadm-config; do kubectl get -n kube-system -o yaml configmap $$i | sed -e "s/featureGates:.../featureGates: {}/" >/tmp/patch.yaml && kubectl patch -n kube-system -o yaml configmap $$i -p "$$(cat /tmp/patch.yaml)"; done' && \

# Ensures that (among others) _work/clear-kvm.img gets deleted when configuring it fails.
.DELETE_ON_ERROR:

_work/start-clear-kvm: test/start_qemu.sh
	mkdir -p _work
	cp $< $@
	sed -i -e "s;\(OVMF.fd\|[a-zA-Z0-9_]*\.log\);$$(pwd)/_work/\1;g" $@
	chmod a+x $@

_work/ssh-clear-kvm: _work/id
	echo "#!/bin/sh" >$@
	echo "exec ssh -p \$${VMM:-1}0022 -oIdentitiesOnly=yes -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oLogLevel=error -i $$(pwd)/_work/id root@localhost \"\$$@\"" >>$@
	chmod u+x $@

_work/OVMF.fd:
	mkdir -p _work
	curl -o $@ https://download.clearlinux.org/image/OVMF.fd

_work/id:
	mkdir -p _work
	ssh-keygen -N '' -f $@

SPDK_SOURCE = vendor/github.com/spdk/spdk
_work/vhost:
	mkdir -p _work
	cd $(SPDK_SOURCE) && ./configure && make -j
	cp -a $(SPDK_SOURCE)/app/vhost/vhost $@

# protobuf API handling
OIM_SPEC := spec.md
OIM_PROTO := pkg/spec/oim.proto

# This is the target for building the temporary OIM protobuf file.
#
# The temporary file is not versioned, and thus will always be
# built on Travis-CI.
$(OIM_PROTO).tmp: $(OIM_SPEC) Makefile
	echo "// Code generated by make; DO NOT EDIT." > "$@"
	cat $< | sed -n -e '/```protobuf$$/,/^```$$/ p' | sed '/^```/d' >> "$@"

# This is the target for building the OIM protobuf file.
#
# This target depends on its temp file, which is not versioned.
# Therefore when built on Travis-CI the temp file will always
# be built and trigger this target. On Travis-CI the temp file
# is compared with the real file, and if they differ the build
# will fail.
#
# Locally the temp file is simply copied over the real file.
$(OIM_PROTO): $(OIM_PROTO).tmp
ifeq (true,$(TRAVIS))
	diff "$@" "$?"
else
	diff "$@" "$?" > /dev/null 2>&1 || cp -f "$?" "$@"
endif

# If this is not running on Travis-CI then for sake of convenience
# go ahead and update the language bindings as well.
ifneq (true,$(TRAVIS))
#build:
#	$(MAKE) -C lib/go
#	$(MAKE) -C lib/cxx
endif

#clean:
#	$(MAKE) -C lib/go $

#clobber: clean
#        $(MAKE) -C lib/go $@
#        rm -f $(OIM_PROTO) $(OIM_PROTO).tmp

# check generated files for violation of standards
test: test_proto
test_proto: $(OIM_PROTO)
	awk '{ if (length > 72) print NR, $$0 }' $? | diff - /dev/null

update: update_spec
update_spec: $(OIM_PROTO)
	$(MAKE) -C pkg/spec

# We need to modify the upstream source code a bit because we want to
# use only gogo/protobuf, not a mixture of gogo/protobuf and
# golang/protobuf. This works because gogo/protobuf is a drop-in
# replacement, but we need to:
# - replace import statements
# - replace some .pb.go files with symlinks to files that we
#   generated from the upstream .proto files with gogofaster
#   (done in pkg/spec)
#
# To upgrade to a different version:
# - "dep ensure -v -update" to pull new code into vendor and/or
#   update the copy of the upstream .proto files under pkg/spec
#   (some are not in vendor)
# - "make update_spec" to re-generate the .pb.go files
update: update_dep
update_dep:
	dep ensure -v
	if [ -d vendor/github.com/golang/protobuf ]; then \
	    echo "vendor/github.com/golang/protobuf not properly ignored, update Gopkg.toml"; \
	    false; \
	fi
	sed -i -e 's;"github.com/golang/protobuf/ptypes/any";any "github.com/gogo/protobuf/types";' \
	       -e 's;"github.com/golang/protobuf/ptypes";ptypes "github.com/gogo/protobuf/types";' \
	       -e 's;"github.com/golang/protobuf/proto";"github.com/gogo/protobuf/proto";' \
	    $$(grep -r -l github.com/golang/protobuf vendor/ | grep '.go$$')
	for pbgo in $(PB_GO_FILES); do \
		ln -sf $$(echo $$pbgo | sed -e 's;[^/]*;;g' -e 's;/;../;g')../pkg/spec/$$pbgo vendor/$$pbgo; \
	done

PB_GO_FILES := \
	github.com/container-storage-interface/spec/lib/go/csi/v0/csi.pb.go \
	github.com/coreos/etcd/auth/authpb/auth.pb.go \
	github.com/coreos/etcd/etcdserver/etcdserverpb/etcdserver.pb.go \
	github.com/coreos/etcd/mvcc/mvccpb/kv.pb.go \
	github.com/googleapis/gnostic/OpenAPIv2/OpenAPIv2.pb.go \
	github.com/googleapis/gnostic/extensions/extension.pb.go \
	google.golang.org/genproto/googleapis/rpc/status/status.pb.go \
	google.golang.org/grpc/health/grpc_health_v1/health.pb.go \

.PHONY: test_protobuf
test: test_protobuf
test_protobuf:
	@ if go list -f '{{ join .Deps "\n" }}' $(foreach i,$(OIM_CMDS),./cmd/$(i)) | grep -q github.com/golang/protobuf; then \
		echo "binaries should not depend on golang/protobuf, use gogo/protobuf instead"; \
		false; \
	fi
