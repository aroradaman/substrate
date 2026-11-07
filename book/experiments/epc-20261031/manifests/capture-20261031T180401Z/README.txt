These are selected live Kubernetes objects observed after API admission,
defaulting and controller reconciliation. They are NOT the exact bytes passed
by ate-setup to server-side apply and are NOT a replayable installation bundle.
Secret objects and private credential files were not requested. ConfigMap
values, literal environment values, command/argument arrays, HTTP header
values, URL fields, annotations, managedFields, status and free-form messages
were removed or redacted. Pod image/status summaries contain selected fields.
Resource names, Secret references, image references and topology remain.
source-inputs.json hashes tracked source inputs; it does not export their
contents. Missing demo resources mean only that they were absent at capture.
Capture is sequential, not an atomic snapshot across Kubernetes resources.
