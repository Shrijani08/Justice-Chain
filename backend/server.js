const express = require('express');
const dotenv = require('dotenv');
const multer = require('multer');
const axios = require('axios');
const fs = require('fs');

dotenv.config();

const app = express();
const PORT = 3000;

// Temporary location for uploaded files
const upload = multer({ dest: 'uploads/' });

app.get('/', (req, res) => {
  res.json({
    message: 'Justice-Chain backend is running!'
  });
});

app.get('/config-test', (req, res) => {
  res.json({
    pinataConfigured: !!process.env.PINATA_JWT
  });
});

// Upload evidence to Pinata/IPFS
app.post('/upload', upload.single('file'), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({
        error: 'No file received'
      });
    }

    const formData = new FormData();

    const fileBuffer = fs.readFileSync(req.file.path);

    const blob = new Blob([fileBuffer], {
      type: req.file.mimetype
    });

    formData.append('file', blob, req.file.originalname);

    const response = await axios.post(
      'https://uploads.pinata.cloud/v3/files',
      formData,
      {
        headers: {
          Authorization: `Bearer ${process.env.PINATA_JWT}`,
          ...formData.getHeaders?.()
        },
        maxBodyLength: Infinity,
      }
    );

    // Delete temporary local copy
    fs.unlinkSync(req.file.path);

    res.json({
      success: true,
      cid: response.data.data.cid
    });

  } catch (error) {
    console.error('IPFS upload failed:', error.response?.data || error.message);

    if (req.file?.path && fs.existsSync(req.file.path)) {
      fs.unlinkSync(req.file.path);
    }

    res.status(500).json({
      success: false,
      error: 'IPFS upload failed'
    });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Justice-Chain backend running on port ${PORT}`);
});