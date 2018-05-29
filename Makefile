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

all: oim-csi-driver-container

test:
	go test $(IMPORT_PATH)/pkg/...
	go vet $(IMPORT_PATH)/pkg/...

coverage:
	mkdir -p _output
	go test -coverprofile _output/cover.out $(IMPORT_PATH)/pkg/...
	go tool cover -html=_output/cover.out -o _output/cover.html

oim-csi-driver:
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-extldflags "-static"' -o _output/$@ ./cmd/$@

%-container: %
	docker build -t $(IMAGE_TAG) -f ./cmd/$*/Dockerfile .

push-%: %-container
	docker push $(IMAGE_TAG)

clean:
	go clean -r -x
	-rm -rf _output

.PHONY: all test coverage clean oim-csi-driver
