package com.retrodev.blastem;
import org.libsdl.app.SDLActivity;
import android.content.ContentResolver;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.util.Log;
import android.view.View;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Map;
import java.util.HashMap;


public class BlastEmActivity extends SDLActivity
{
	static final int DOC_TREE_CODE = 4242;
	boolean chooseDirInProgress = false;
	String chooseDirResult = null;
	Map<String, Uri> uriMap = new HashMap<String, Uri>();
	@Override
    protected void onCreate(Bundle savedInstanceState) {
		super.onCreate(savedInstanceState);
		
		//set immersive mode on devices that support it
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
			View blah = mSurface;
			blah.setSystemUiVisibility(
				View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
			);
		}
	}
	
	public String getRomPath() {
		if (chooseDirInProgress) {
			if (chooseDirResult != null) {
				chooseDirInProgress = false;
				return chooseDirResult;
			}
			return null;
		}
		String extStorage = Environment.getExternalStorageDirectory().getAbsolutePath();
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
			return extStorage;
		}
		chooseDirInProgress = true;
		Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
		//intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(extStorage));
		/*intent.putExtra("android.content.extra.SHOW_ADVANCED", true);
		intent.putExtra("android.content.extra.FANCY", true);
		intent.putExtra("android.content.extra.SHOW_FILESIZE", true);*/
		startActivityForResult(intent, DOC_TREE_CODE);
		return null;
	}
	
	public String[] readUriDir(String uriString) {
		Uri uri = uriMap.get(uriString);
		if (uri == null) {
			return new String[0];
		}
		//adapted from some androidx.documentfile
		final ContentResolver resolver = getContentResolver();
        final ArrayList<String> results = new ArrayList<>();

        Cursor c = null;
        try {
			Log.i("BlastEm", "getTreeDocumentId: " + DocumentsContract.getTreeDocumentId(uri));
			final Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri,
                DocumentsContract.getTreeDocumentId(uri)
			);
            c = resolver.query(
				childrenUri, new String[] {
					DocumentsContract.Document.COLUMN_DOCUMENT_ID,
					DocumentsContract.Document.COLUMN_DISPLAY_NAME,
					DocumentsContract.Document.COLUMN_MIME_TYPE
				}, null, null, null
			);
            while (c.moveToNext()) {
                final String documentId = c.getString(0);
				String name = c.getString(1);
				final String mime = c.getString(2);
                final Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(uri,
                        documentId);
                uriMap.put(uriString + "/" + name, documentUri);
				if (DocumentsContract.Document.MIME_TYPE_DIR.equals(mime)) {
					name += "/";
				}
				results.add(name);
            }
        } catch (Exception e) {
            Log.w("BlastEm", "Failed query: " + e);
        } finally {
            if (c != null) {
				c.close();
			}
        }
		return results.toArray(new String[0]);
	}
	
	public int openUriAsFd(String uriString, String mode) {
		Uri uri = uriMap.get(uriString);
		if (uri == null) {
			Log.w("BlastEm", "Did not find URI in map: " + uriString);
			return 0;
		}
		if (mode.equals("rb")) {
			mode = "r";
		} else if (mode.equals("wb")) {
			mode = "w";
		}
		try {
			ParcelFileDescriptor pfd = getContentResolver().openFileDescriptor(uri, mode);
			if (pfd != null) {
				return pfd.detachFd();
			}
			Log.w("BlastEm", "openFileDescriptor returned null: " + uriString);
		} catch (FileNotFoundException e) {
			Log.w("BlastEm", "Failed to open URI: " + e);
		} catch (IllegalArgumentException e) {
			Log.w("BlastEm", "Failed to open URI: " + e);
		}
		return 0;
	}
	
	public String[] getAssetsList(String path) {
		try {
			return getAssets().list(path);
		} catch (IOException e) {
			Log.w("BlastEm", "Failed to get assets at '" + path + "': " + e);
		}
		return new String[0];
	}
	
	@Override
	public void onActivityResult(int requestCode, int resultCode, Intent resultData) {
		if (requestCode == DOC_TREE_CODE) {
			if (resultCode == RESULT_OK && resultData != null) {
				Uri uri = resultData.getData();
				getContentResolver().takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
				chooseDirResult = uri.toString();
				uriMap.put(chooseDirResult, uri);
				Log.i("BlastEm", "ACTION_OPEN_DOCUMENT_TREE got URI " + chooseDirResult);
			} else {
				Log.i("BlastEm", "ACTION_OPEN_DOCUMENT_TREE failed! ");
				chooseDirResult = "";
			}
		} else {
			super.onActivityResult(requestCode, resultCode, resultData);
		}
	}
}