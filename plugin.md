SourceCodeScanStep

step([$class: 'SourceCodeScanStep',
mdsscInstance: 'http://35.156.106.42/', // URL-ul MDSSC
credentialsId: 'key', // ID-ul credențialei (Secret Text)
connectionId: '019ea811-962e-7573-96af-735a2ca9ba17', // Connection (storageId)
repository: 'Z2l0aHViLWlvYW5hLzEyNjQyODAxNTU=', // Repository (base64 id)
branch: 'main', // branch-ul de scanat
workflowId: '6a27260e006f2db36a982671', // optional, gol = default
vulnerabilityThreshold: 'none', // none|low|medium|high|critical
failOnSecret: true,
failOnMalware: true,
scanTimeout: 900, // secunde
pollInterval: 10 // secunde
])

ArtifactScanStep

step([$class: 'ArtifactScanStep',
mdsscInstance: 'http://35.156.106.42/', // URL-ul MDSSC
credentialsId: 'key', // ID-ul credențialei (Secret Text)
filePath: 'target/app.jar', // calea artefactului (relativ la workspace)
workflowId: '6a27260e006f2db36a982671', // optional, gol = default
vulnerabilityThreshold: 'critical', // none|low|medium|high|critical
failOnSecret: true,
failOnMalware: true,
scanTimeout: 900, // secunde
pollInterval: 10, // secunde
maxFileSizeMb: 100 // peste limită → skip (UNSTABLE)
])
